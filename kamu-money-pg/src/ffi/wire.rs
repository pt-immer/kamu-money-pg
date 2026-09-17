//! Binary `SEND`/`RECEIVE`: each family's payload on the wire, and the raw recv FFI.
//!
//! Needed because tokio-postgres and sqlx request BINARY result format by default, so a Rust
//! client reading a native column hits this immediately -- while every in-backend `#[pg_test]`
//! speaks the text protocol, which is exactly why nothing here noticed for so long.
//!
//! `recv` cannot be a plain `#[pg_extern]`: it takes `internal` (a `StringInfo`), which pgrx has
//! no safe mapping for. Binary input is NO LESS UNTRUSTED than text input, so each recv performs
//! the same checks its type's text input function does rather than believing the bytes it was
//! handed. The wire is little-endian on both families -- the codec fixes the byte order, not the
//! platform -- which is the opposite of PostgreSQL's network-order convention for built-in
//! types; a hand-written client must not assume big-endian.

use pgrx::datum::IntoDatum;
use pgrx::prelude::*;

use crate::kmoney_mixed;
use crate::safe::payload::{
    PAYLOAD_BYTES, PINNED_PAYLOAD_BYTES, Payload, PinnedPayload, ValidationError, validate_payload,
    validate_pinned,
};
use crate::safe::{raise, validated_or_error};

// BINARY I/O: `SEND` and `RECEIVE`.
//
// Without these a client that asks for binary result format gets
// `no binary output function available for type kmoney` -- and tokio-postgres and sqlx request
// binary for result columns BY DEFAULT, so a Rust program reading a native column hit it
// immediately. Every test in this crate is an in-database `#[pg_test]` speaking the text
// protocol, which is exactly why nothing here noticed.
//
// The wire form is the same payload each family stores: 16 little-endian unit bytes for a
// pinned type, plus a 2-byte little-endian ISO numeric code for the mixed one. Both are
// endian-explicit already, so send is a copy and recv is a copy plus the same checks that
// family's text input function performs. That is deliberate -- binary input is no less
// untrusted than text input, and a client that sends garbage bytes must be refused rather
// than believed.
//
// `send` is an ordinary `#[pg_extern]`. `recv` cannot be: it takes `internal` (a `StringInfo`),
// which pgrx 0.19.2 has no safe mapping for, so it is a raw `#[pg_guard] extern "C-unwind"`
// function with a hand-written finfo record, declared through `extension_sql!` by symbol name.

/// `send(kmoney_mixed) -> bytea`.
#[pg_extern(immutable, parallel_safe, requires = ["money_shell_types"])]
fn kmoney_mixed_send(value: kmoney_mixed) -> Vec<u8> {
    validated_or_error(value.payload(), "kmoney_mixed").payload().to_bytes().to_vec()
}

/// Read exactly `N` payload bytes off the wire, refusing short and long messages.
///
/// Shared by both families: the width is the only thing that differs before
/// validation, and validation is per family.
///
/// # Safety
/// Called only by PostgreSQL through a `RECEIVE` slot, which guarantees `fcinfo` is valid and
/// argument 0 is a non-null `internal` pointing at a `StringInfo`.
unsafe fn read_wire_bytes<const N: usize>(fcinfo: pg_sys::FunctionCallInfo, context: &str) -> [u8; N] {
    // Keep this check in release builds: the next operation indexes PostgreSQL's flexible array.
    // A bad arity indicates a registration or catalog error, not user input.
    // SAFETY: this function's PostgreSQL contract guarantees `fcinfo` points to valid call data.
    if unsafe { (*fcinfo).nargs } < 1 {
        error!("{context}: RECEIVE called with no argument");
    }
    // SAFETY: PostgreSQL populates `args` for every call through this slot.
    let arg = unsafe { (*fcinfo).args.as_ptr().read().value };
    let buf = arg.cast_mut_ptr::<pg_sys::StringInfoData>();

    let mut bytes = [0u8; N];
    // `try_from` rather than `as`: 16 and 18 fit `c_int` on every supported platform so this
    // cannot fire, but an `as` here would silently truncate if a payload width ever grew, and a
    // truncated length passed to pq_copymsgbytes would under-fill `bytes` and leave the tail
    // of a money value uninitialised.
    let want = core::ffi::c_int::try_from(N)
        .expect("payload widths are 16 or 18, which fit c_int on every supported platform");
    // `pq_copymsgbytes` rather than `pq_getmsgbytes`: it copies into our own buffer, so no
    // reference is ever constructed over the message's memory. It raises if the message is
    // short, which is the correct answer to a truncated payload.
    // Pinned by `recv_refuses_a_truncated_binary_payload`.
    //
    // SAFETY: `buf` is the StringInfo PostgreSQL passed; `bytes` is exactly N bytes.
    unsafe {
        pg_sys::pq_copymsgbytes(
            buf,
            // Untyped `.cast()`: pq_copymsgbytes's buffer parameter is `*mut c_void` on
            // PG18 and `*mut c_char` on PG15, so a turbofish compiles on one major and
            // fails on another. Inference picks whichever this major declares.
            bytes.as_mut_ptr().cast(),
            want,
        );
        // Refuse trailing bytes. Without this, a longer message would be silently accepted and
        // its tail ignored -- the shape of every "we read what we expected and moved on" bug.
        // Pinned by `recv_refuses_a_binary_payload_with_trailing_bytes`.
        pg_sys::pq_getmsgend(buf);
    }
    bytes
}

/// Read an 18-byte mixed payload off the wire, validating it exactly as the text path validates.
///
/// # Safety
/// See `read_wire_bytes`; this forwards the same RECEIVE contract.
unsafe fn recv_payload(fcinfo: pg_sys::FunctionCallInfo, context: &str) -> Payload {
    // SAFETY: forwarded RECEIVE contract.
    let bytes: [u8; PAYLOAD_BYTES] = unsafe { read_wire_bytes(fcinfo, context) };
    let payload = Payload::from_bytes(bytes);
    if let Err(error) = validate_payload(payload) {
        match error {
            ValidationError::OutOfDomain { currency, .. } => {
                raise::out_of_range(format!(
                    "{context}: received {} amount is outside the domain |units| <= 10^36 - 1",
                    currency.alpha3()
                ));
            }
            ValidationError::UnknownCurrency { .. } => {
                raise::invalid_binary(format!("{context}: {error}"));
            }
        }
    }
    payload
}

/// `recv(internal) -> kmoney_mixed`.
///
/// # Safety
/// See `recv_payload`, which is private -- a plain code span rather than an intra-doc link,
/// because a public item linking to a private one is a rustdoc error and would break the
/// docs.rs build of a crate this repository's gate had just declared releasable.
#[unsafe(no_mangle)]
#[pg_guard]
pub unsafe extern "C-unwind" fn kmoney_mixed_recv(fcinfo: pg_sys::FunctionCallInfo) -> pg_sys::Datum {
    // SAFETY: this entry point has the same RECEIVE contract and forwards `fcinfo` unchanged.
    let payload = unsafe { recv_payload(fcinfo, "kmoney_mixed") };
    kmoney_mixed::from_payload(payload)
        .into_datum()
        .unwrap_or_else(|| error!("kmoney_mixed: could not allocate a received value"))
}

/// Name the SQL function a RECEIVE call arrived through, so a shared symbol's
/// refusal still says which type refused -- `kmoney_usd_recv`, not a generic tag.
///
/// # Safety
/// `fcinfo` must be valid call data; PostgreSQL guarantees that for a RECEIVE slot.
unsafe fn recv_function_name(fcinfo: pg_sys::FunctionCallInfo) -> String {
    // SAFETY: RECEIVE calls always carry a populated `flinfo`.
    let oid = unsafe { (*(*fcinfo).flinfo).fn_oid };
    // SAFETY: `get_func_name` takes any OID and returns a palloc'd name or NULL.
    let name = unsafe { pg_sys::get_func_name(oid) };
    if name.is_null() {
        "kmoney_pinned_recv".to_string()
    } else {
        // SAFETY: a non-null result is a NUL-terminated palloc'd C string.
        unsafe { core::ffi::CStr::from_ptr(name) }.to_string_lossy().into_owned()
    }
}

/// `recv(internal) -> kmoney_<code>` -- ONE symbol serving all 178 pinned types.
///
/// The pinned payload is currency-less, so the bytes mean exactly the same
/// thing for every pinned type and the `RETURNS` clause of the per-type
/// `CREATE FUNCTION` declaration (generated by `build.rs`) is what types the
/// result. Sharing the symbol therefore cannot confuse currencies the way a
/// shared arithmetic symbol would: there is no currency in the value to
/// confuse. Validation is the same domain check the text input path applies --
/// binary input is no less untrusted than text input.
///
/// # Safety
/// Called only by PostgreSQL through a `RECEIVE` slot; see `read_wire_bytes`.
#[unsafe(no_mangle)]
#[pg_guard]
pub unsafe extern "C-unwind" fn kmoney_pinned_recv(fcinfo: pg_sys::FunctionCallInfo) -> pg_sys::Datum {
    // SAFETY: this entry point has the same RECEIVE contract and forwards `fcinfo` unchanged.
    let bytes: [u8; PINNED_PAYLOAD_BYTES] = unsafe { read_wire_bytes(fcinfo, "kmoney_pinned_recv") };
    let payload = PinnedPayload::from_bytes(bytes);
    if validate_pinned(payload).is_err() {
        // SAFETY: same valid `fcinfo`; only the function name is read.
        let context = unsafe { recv_function_name(fcinfo) };
        raise::out_of_range(format!("{context}: received amount is outside the domain |units| <= 10^36 - 1"));
    }

    // SAFETY: a PostgreSQL backend has a valid CurrentMemoryContext; `palloc` returns at least
    // PINNED_PAYLOAD_BYTES writable bytes or raises.
    let dst = unsafe { pg_sys::palloc(PINNED_PAYLOAD_BYTES).cast::<u8>() };
    // SAFETY: source and destination are distinct and each spans PINNED_PAYLOAD_BYTES.
    // PostgreSQL owns and later releases `dst`.
    unsafe {
        core::ptr::copy_nonoverlapping(bytes.as_ptr(), dst, PINNED_PAYLOAD_BYTES);
    }
    pg_sys::Datum::from(dst)
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use std::path::{Path, PathBuf};

    use pgrx::prelude::*;
    use tempfile::TempDir;

    struct BinaryCopy {
        _directory: TempDir,
        bytes: Vec<u8>,
        bad: PathBuf,
    }

    fn temporary_directory(tag: &str) -> TempDir {
        tempfile::Builder::new()
            .prefix(&format!("kmoney-{tag}-"))
            .tempdir_in("/tmp")
            .expect("created a private temporary directory")
    }

    fn sql_path(path: &Path) -> String {
        path.to_str().expect("temporary path is valid UTF-8").replace('\'', "''")
    }

    /// A mixed column still takes anything: currency erasure is the type's contract.
    /// Binary I/O round-trips, and refuses what the text path refuses.
    ///
    /// Exercises the binary protocol used by clients such as tokio-postgres and sqlx.
    #[pg_test]
    fn the_binary_wire_round_trips_and_is_not_more_trusted_than_text() {
        // NOTE: `recv` cannot be called directly from SQL -- its argument is `internal`, which
        // has no SQL literal, and that is a deliberate PostgreSQL restriction rather than a gap
        // here. So recv is exercised the way a real binary-protocol client reaches it: the
        // `COPY ... (FORMAT BINARY)` drives `kmoney_mixed_send` and `kmoney_mixed_recv`; `INSERT ... SELECT`
        // only copies internal datums.

        Spi::run("CREATE TABLE bin_io (amount kmoney_mixed)").expect("table created");
        Spi::run("INSERT INTO bin_io VALUES ('IDR -16000.50'), ('USD 0.000000000000000001')")
            .expect("rows inserted");

        // BOTH families advertise both directions. Without RECEIVE a binary
        // COPY dump would be write-only, a `binary = true` logical-replication
        // subscription could never complete its initial sync, and PostgreSQL
        // offers no `ALTER TYPE ... RECEIVE` to add it after the freeze.
        let binary_ready = Spi::get_one::<bool>(
            "SELECT bool_and(typsend <> 0) AND bool_and(typreceive <> 0)
               FROM pg_type WHERE typname IN ('kmoney_mixed', 'kmoney_usd')",
        )
        .expect("query ran")
        .expect("row");
        assert!(binary_ready, "both families declare SEND and RECEIVE");

        // send produces exactly the stored bytes: 16 for a pinned value, 18 for
        // the erased one still carrying its ISO code.
        let widths = Spi::get_one::<String>(
            "SELECT format(
                 '%s/%s',
                 octet_length(kmoney_usd_send('1.00'::kmoney_usd)),
                 octet_length(kmoney_mixed_send('USD 1.00'::kmoney_mixed))
             )",
        )
        .expect("query ran")
        .expect("row");
        assert_eq!(widths, "16/18", "each binary form is that type's stored payload");

        // COPY (FORMAT BINARY) out and back in is the real client path: it calls `kmoney_mixed_send`
        // writing the file and `kmoney_mixed_recv` reading it -- the two functions the catalog just
        // promised. `TempDir` gives each test a private path and removes it on drop.
        let directory = temporary_directory("roundtrip");
        let path = directory.path().join("wire.bin");
        let path_sql = sql_path(&path);
        Spi::run(&format!("COPY bin_io TO '{path_sql}' (FORMAT BINARY)")).expect("send: COPY out");
        Spi::run("CREATE TABLE bin_copy (LIKE bin_io)").expect("table created");
        Spi::run(&format!("COPY bin_copy FROM '{path_sql}' (FORMAT BINARY)")).expect("recv: COPY in");

        // recv must reconstruct the exact payload. A `JOIN USING(amount)` can NOT detect a
        // value-corrupting recv: a mangled row fails to pair and drops out of the inner join,
        // leaving the mismatch count at zero -- a tautology. Compare the ORDERED text projections
        // of both tables instead; any single corrupted byte changes a text form and breaks the
        // array equality.
        let intact = Spi::get_one::<bool>(
            "SELECT (SELECT array_agg(amount::text ORDER BY amount::text) FROM bin_io)
                  = (SELECT array_agg(amount::text ORDER BY amount::text) FROM bin_copy)",
        )
        .expect("query ran")
        .expect("row");
        assert!(intact, "the binary wire round trip changed a value");
        let copied = Spi::get_one::<i64>("SELECT count(*) FROM bin_copy").expect("query ran").expect("row");
        assert_eq!(copied, 2, "both rows must survive send -> recv");
    }

    /// The pinned wire round-trips through the SHARED recv symbol: 16 currency-less
    /// bytes in, typed by the declaration's RETURNS clause, validated as text is.
    #[pg_test]
    fn the_pinned_binary_wire_round_trips() {
        Spi::run("CREATE TABLE pin_io (amount kmoney_usd)").expect("table created");
        Spi::run("INSERT INTO pin_io VALUES ('-16000.50'), ('0.000000000000000001')").expect("rows inserted");

        let directory = temporary_directory("pin-roundtrip");
        let path = directory.path().join("wire.bin");
        let path_sql = sql_path(&path);
        Spi::run(&format!("COPY pin_io TO '{path_sql}' (FORMAT BINARY)")).expect("send: COPY out");
        Spi::run("CREATE TABLE pin_copy (LIKE pin_io)").expect("table created");
        Spi::run(&format!("COPY pin_copy FROM '{path_sql}' (FORMAT BINARY)")).expect("recv: COPY in");

        let intact = Spi::get_one::<bool>(
            "SELECT (SELECT array_agg(amount::text ORDER BY amount::text) FROM pin_io)
                  = (SELECT array_agg(amount::text ORDER BY amount::text) FROM pin_copy)",
        )
        .expect("query ran")
        .expect("row");
        assert!(intact, "the pinned binary wire round trip changed a value");
        let copied = Spi::get_one::<i64>("SELECT count(*) FROM pin_copy").expect("query ran").expect("row");
        assert_eq!(copied, 2, "both rows must survive send -> recv");
    }

    /// The shared pinned recv applies the same domain check as pinned text input,
    /// and its refusal names the per-type SQL function it was reached through --
    /// the shared symbol must not cost the error its type context.
    ///
    /// One-row one-column BINARY COPY of a 16-byte field: 11 signature + 4 flags +
    /// 4 header-extension + 2 field-count + 4 field-length + 16 payload + 2 trailer,
    /// so the payload spans `[25..41]`.
    #[pg_test(error = "kmoney_usd_recv: received amount is outside the domain |units| <= 10^36 - 1")]
    fn pinned_recv_refuses_an_out_of_domain_binary_payload() {
        let mut copy = binary_copy_of("1.00", "kmoney_usd", "pin-domain");
        let out_of_domain: i128 = 1_000_000_000_000_000_000_000_000_000_000_000_000;
        copy.bytes[25..41].copy_from_slice(&out_of_domain.to_le_bytes());
        recv_bytes("pin_recv_bad", "kmoney_usd", &copy.bad, &copy.bytes);
    }

    /// Binary input applies the same domain validation as text input. PostgreSQL writes the
    /// COPY framing (so the file is well-formed); we corrupt only the 18-byte `kmoney_mixed` field in
    /// place -- overwriting the little-endian units and leaving the currency code valid, so it is
    /// the DOMAIN check that fires with a kamu_money_core-owned (version-stable) message.
    #[pg_test(error = "kmoney_mixed: received USD amount is outside the domain |units| <= 10^36 - 1")]
    fn recv_refuses_an_out_of_domain_binary_payload() {
        let mut copy = binary_copy_of("USD 1.00", "kmoney_mixed", "domain");
        // 10^36 is one past the domain top (|units| <= 10^36 - 1). Overwrite the 16-byte LE units;
        // bytes 41..43 (the currency code = USD) are left intact so the domain check is what fires.
        let out_of_domain: i128 = 1_000_000_000_000_000_000_000_000_000_000_000_000;
        copy.bytes[25..41].copy_from_slice(&out_of_domain.to_le_bytes());
        recv_bytes("recv_bad", "kmoney_mixed", &copy.bad, &copy.bytes);
    }

    // -----------------------------------------------------------------------------------
    // recv is the ONLY path that takes attacker-shaped bytes straight into an unsafe FFI
    // function, so its refusals are pinned one at a time below. PostgreSQL writes the COPY
    // framing so the file is always well-formed; each test then crafts exactly one defect.
    //
    // One-row one-column BINARY COPY layout: 11 signature + 4 flags + 4 header-extension +
    // 2 field-count + 4 field-length + 18 payload + 2 trailer = 45 bytes. So the field length
    // is `[21..25]` (int32, NETWORK order), the payload `[25..43]` (16 LE units, then the
    // 2 LE ISO code), and the trailer `[43..]`.
    // -----------------------------------------------------------------------------------

    /// Write one valid single-row BINARY COPY file in a private, self-cleaning directory.
    fn binary_copy_of(literal: &str, sql_type: &str, tag: &str) -> BinaryCopy {
        let directory = temporary_directory(tag);
        let good = directory.path().join("good.bin");
        let bad = directory.path().join("bad.bin");
        Spi::run(&format!("COPY (SELECT '{literal}'::{sql_type}) TO '{}' (FORMAT BINARY)", sql_path(&good)))
            .expect("wrote a valid binary payload");
        let bytes = std::fs::read(&good).expect("read the good payload");
        BinaryCopy { _directory: directory, bytes, bad }
    }

    /// Feed crafted bytes back in as a BINARY COPY, so the type's recv function runs on them.
    fn recv_bytes(table: &str, sql_type: &str, path: &Path, bytes: &[u8]) {
        std::fs::write(path, bytes).expect("wrote the crafted payload");
        Spi::run(&format!("CREATE TABLE {table} (amount {sql_type})")).expect("table created");
        Spi::run(&format!("COPY {table} FROM '{}' (FORMAT BINARY)", sql_path(path))).ok();
    }

    /// recv must REFUSE a short message, not under-fill its buffer. This is the memory-safety
    /// half of the recv contract: `payload` is a fixed `[u8; 18]`, and if `pq_copymsgbytes` did
    /// not raise when fewer than 18 bytes remain, the tail would stay UNINITIALISED and be
    /// reinterpreted as units — money read out of whatever happened to be in that memory.
    /// `recv_payload` asserts this in a comment; this is the proof.
    ///
    /// The field length is cut to 10 AND the payload truncated to match, so the file stays
    /// self-consistent and it is recv, not COPY's own framing check, that refuses.
    #[pg_test(error = "insufficient data left in message")]
    fn recv_refuses_a_truncated_binary_payload() {
        let copy = binary_copy_of("USD 1.00", "kmoney_mixed", "short");
        let mut short = copy.bytes[..21].to_vec();
        short.extend_from_slice(&10_i32.to_be_bytes());
        short.extend_from_slice(&copy.bytes[25..35]);
        short.extend_from_slice(&copy.bytes[43..]);
        recv_bytes("recv_short", "kmoney_mixed", &copy.bad, &short);
    }

    /// recv must REFUSE trailing bytes rather than take the 18 it wanted and ignore the rest —
    /// "we read what we expected and moved on" is how a re-framed or version-skewed payload gets
    /// silently accepted as a different amount.
    ///
    /// The expected message is `pq_getmsgend`'s, NOT COPY's, and that distinction is the whole
    /// point: delete the `pq_getmsgend` call and PostgreSQL's own post-check still errors, but
    /// with "improper binary format in file". So this goes red on exactly the guard it pins.
    #[pg_test(error = "invalid message format")]
    fn recv_refuses_a_binary_payload_with_trailing_bytes() {
        let copy = binary_copy_of("USD 1.00", "kmoney_mixed", "long");
        let mut long = copy.bytes[..21].to_vec();
        long.extend_from_slice(&26_i32.to_be_bytes());
        long.extend_from_slice(&copy.bytes[25..43]);
        long.extend_from_slice(&[0_u8; 8]);
        long.extend_from_slice(&copy.bytes[43..]);
        recv_bytes("recv_long", "kmoney_mixed", &copy.bad, &long);
    }

    /// Binary is not more trusted than text, and BOTH of recv's checks have to prove it. The
    /// domain half is pinned by `recv_refuses_an_out_of_domain_binary_payload`; this is the
    /// currency half. The units are left valid and only the 2-byte ISO code is overwritten with
    /// 0, which is not an assigned ISO 4217 numeric code.
    #[pg_test(error = "kmoney_mixed: stored ISO 4217 numeric code 0 is not in kamu_money_core's table")]
    fn recv_refuses_a_binary_payload_whose_currency_is_unknown() {
        let mut copy = binary_copy_of("USD 1.00", "kmoney_mixed", "nocur");
        copy.bytes[41..43].copy_from_slice(&0_u16.to_le_bytes());
        recv_bytes("recv_nocur", "kmoney_mixed", &copy.bad, &copy.bytes);
    }
}
