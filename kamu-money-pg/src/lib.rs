//! `kmoney`: money as native PostgreSQL types, one per currency.
//!
//! Every ISO 4217 code gets its own fixed-width type -- `kmoney_usd`,
//! `kmoney_idr`, and the rest -- 16 bytes of canonical units with the currency
//! in the catalog rather than the value. Cross-currency arithmetic has no
//! operator to resolve and fails while the query is parsed. `kmoney_mixed`
//! remains the one deliberately currency-erased type (18 bytes, units plus the
//! ISO numeric code) for a column that must hold several currencies; it has no
//! arithmetic. `numeric(36,18)` is often smaller than either, but can round
//! excess precision before constraints inspect it.
//!
//! Text parsing, rendering, currency lookup, and arithmetic delegate to `kamu_money_core`.

// Match money-core's named restriction/nursery lints without enabling either
// unstable group wholesale. FFI casts are denied globally.
#![deny(clippy::all, clippy::pedantic)]
#![deny(unsafe_op_in_unsafe_fn, clippy::undocumented_unsafe_blocks)]
#![deny(
    clippy::arithmetic_side_effects,
    clippy::as_conversions,
    clippy::cast_lossless,
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::cast_precision_loss,
    clippy::cast_ptr_alignment,
    clippy::cast_sign_loss,
    clippy::missing_const_for_fn,
    clippy::use_self
)]

extern crate alloc;
use pgrx::prelude::*;

use safe::payload::{PAYLOAD_BYTES, PINNED_PAYLOAD_BYTES, Payload, PinnedPayload};

::pgrx::pg_module_magic!(name, version);

mod ffi;
mod safe;

/// Define a **fixed-length** PostgreSQL type over an 18-byte `#[repr(C)]` payload.
///
/// # Why this is not `#[derive(PostgresType)]`
///
/// pgrx 0.19.2's derive hardcodes `INTERNALLENGTH = variable`, so it cannot
/// declare this fixed-width value. The extension therefore owns `CREATE TYPE`
/// and the datum ABI implementations.
///
/// PostgreSQL stores the 18-byte value by reference because `Datum` holds at
/// most 8 bytes. Function results use `palloc` in the current memory context;
/// fixed width removes the varlena header and TOAST eligibility, not allocation.
macro_rules! fixed_length_money_type {
    ($(#[$meta:meta])* $t:ident) => {
        $(#[$meta])*
        #[derive(Copy, Clone)]
        #[repr(C)]
        #[allow(non_camel_case_types)]
        pub struct $t(Payload);

        // Compile-time checks bind the Rust layout to `INTERNALLENGTH = 18`
        // and `ALIGNMENT = char`.
        const _: () = assert!(
            size_of::<$t>() == PAYLOAD_BYTES,
            "the struct width must equal the INTERNALLENGTH declared to PostgreSQL"
        );
        const _: () = assert!(
            align_of::<$t>() == 1,
            "ALIGNMENT = char promises PostgreSQL may place this value at any address"
        );

        impl $t {
            /// Canonical units, as `kamu_money_core` counts them.
            fn units(self) -> i128 {
                self.0.units()
            }

            /// The stored ISO 4217 numeric code.
            const fn code(self) -> u16 {
                self.0.code()
            }

            fn new(units: i128, code: u16) -> Self {
                Self(Payload::from_parts(units, code))
            }

            const fn payload(self) -> Payload {
                self.0
            }

            const fn from_payload(payload: Payload) -> Self {
                Self(payload)
            }
        }

    };
}

/// Define a **per-currency** PostgreSQL type over a 16-byte `#[repr(C)]` payload.
///
/// The currency is the SQL type, not a field, so the value is the amount and
/// nothing else. `kmoney_usd + kmoney_idr` therefore has no operator at all and
/// fails while the query is parsed, rather than reaching a currency check
/// inside one.
///
/// # Why the function names are parameters
///
/// A `macro_rules!` can neither lowercase nor concatenate identifiers, so it
/// cannot build `kmoney_usd_out` from `kmoney_usd`. Rather than hand-write the
/// text I/O beside every invocation — 178 chances to mistype a name that
/// nothing would catch — the caller passes every identifier already declined
/// and this macro only *uses* them. Deriving them is `build.rs`'s job, where
/// `format_ident!` can, and the manifest it emits is the flat table of
/// declensions those invocations read from.
///
/// The macro is therefore purely structural: one definition, and every
/// generated currency differs from it in nothing but its names.
macro_rules! pinned_money_type {
    (
        $(#[$meta:meta])*
        $t:ident : $currency:ty,
        concrete = $concrete:literal,
        io = [$in:ident, $out:ident, $send:ident],
        cmp = [$eq:ident, $ne:ident, $lt:ident, $le:ident, $gt:ident, $ge:ident],
        arith = [$add:ident, $sub:ident],
        agg = [$accum:ident, $combine:ident, $final:ident],
        split = [$div:ident, $allocate:ident],
        hash = $hash:ident $(,)?
    ) => {
        $(#[$meta])*
        #[derive(Copy, Clone)]
        #[repr(C)]
        #[allow(non_camel_case_types)]
        pub struct $t(PinnedPayload);

        // Binds the Rust layout to `INTERNALLENGTH = 16` and `ALIGNMENT = char`.
        const _: () = assert!(
            size_of::<$t>() == PINNED_PAYLOAD_BYTES,
            "the struct width must equal the INTERNALLENGTH declared to PostgreSQL"
        );
        const _: () = assert!(
            align_of::<$t>() == 1,
            "ALIGNMENT = char promises PostgreSQL may place this value at any address"
        );

        impl safe::pinned::sealed::Sealed for $t {}

        impl safe::pinned::PinnedCurrency for $t {
            type Currency = $currency;
            // `stringify!` is also what `SqlTranslatable::TYPE_IDENT` uses, so the
            // Rust name and the SQL name agree by construction rather than by
            // assertion -- which is what lets `rust_regtypein` resolve the OID.
            const SQL_NAME: &'static str = stringify!($t);

            fn units(self) -> i128 {
                self.0.units()
            }

            fn from_units(units: i128) -> Self {
                Self(PinnedPayload::from_units(units))
            }
        }

        impl $t {
            /// Canonical units. Inherent as well as on the trait, so the operator
            /// bodies below read as arithmetic rather than as trait dispatch.
            const fn units(self) -> i128 {
                self.0.units()
            }

            const fn payload(self) -> PinnedPayload {
                self.0
            }

            const fn from_payload(payload: PinnedPayload) -> Self {
                Self(payload)
            }
        }

        crate::ffi::impl_pinned_datum!($t);

        #[doc(hidden)]
        #[pg_extern(immutable, parallel_safe, requires = ["money_shell_types"])]
        fn $in(input: &core::ffi::CStr) -> $t {
            match input.to_str() {
                Ok(text) => safe::pinned::parse_pinned(text),
                Err(e) => safe::raise::invalid_text(format!(
                    "{}: input is not valid UTF-8: {e}",
                    <$t as safe::pinned::PinnedCurrency>::SQL_NAME
                )),
            }
        }

        #[doc(hidden)]
        #[pg_extern(immutable, parallel_safe, requires = ["money_shell_types"])]
        fn $out(value: $t) -> alloc::ffi::CString {
            let rendered = safe::pinned::render_pinned(value);
            alloc::ffi::CString::new(rendered).unwrap_or_else(|e| {
                error!(
                    "{}: rendered form contains a NUL byte: {e}",
                    <$t as safe::pinned::PinnedCurrency>::SQL_NAME
                )
            })
        }

        #[doc(hidden)]
        #[pg_extern(immutable, parallel_safe, requires = ["money_shell_types"])]
        fn $send(value: $t) -> Vec<u8> {
            safe::pinned::send_pinned(value)
        }

        // COMPARISON. Within one currency there is nothing left to check: the
        // SQL type already guarantees both operands are this currency, so these
        // read units and nothing else.
        //
        // Note what is absent. There is no currency check to make and no
        // cross-currency comparison to refuse: ordering here is TOTAL, because
        // the SQL type fixes the currency, so the question a check would answer
        // cannot be asked. Equality is likewise total, and for the same reason.
        // `kmoney_mixed`, which does carry a currency in the value, registers
        // equality alone and no ordering at all.
        //
        // Deliberately NO btree or hash operator class. These are sequential-scan
        // predicates only. The absent default-opclass ordering is the one surface
        // YugabyteDB's planner will not resolve for a custom type, and its
        // absence is what keeps these types byte-exact there.
        #[pg_operator(immutable, parallel_safe, requires = [$concrete])]
        #[opname(=)]
        #[commutator(=)]
        #[negator(<>)]
        #[restrict(eqsel)]
        #[join(eqjoinsel)]
        const fn $eq(a: $t, b: $t) -> bool {
            a.units() == b.units()
        }

        #[pg_operator(immutable, parallel_safe, requires = [$concrete])]
        #[opname(<>)]
        #[commutator(<>)]
        #[negator(=)]
        #[restrict(neqsel)]
        #[join(neqjoinsel)]
        const fn $ne(a: $t, b: $t) -> bool {
            a.units() != b.units()
        }

        #[pg_operator(immutable, parallel_safe, requires = [$concrete])]
        #[opname(<)]
        #[commutator(>)]
        #[negator(>=)]
        #[restrict(scalarltsel)]
        #[join(scalarltjoinsel)]
        const fn $lt(a: $t, b: $t) -> bool {
            a.units() < b.units()
        }

        #[pg_operator(immutable, parallel_safe, requires = [$concrete])]
        #[opname(<=)]
        #[commutator(>=)]
        #[negator(>)]
        #[restrict(scalarlesel)]
        #[join(scalarlejoinsel)]
        const fn $le(a: $t, b: $t) -> bool {
            a.units() <= b.units()
        }

        #[pg_operator(immutable, parallel_safe, requires = [$concrete])]
        #[opname(>)]
        #[commutator(<)]
        #[negator(<=)]
        #[restrict(scalargtsel)]
        #[join(scalargtjoinsel)]
        const fn $gt(a: $t, b: $t) -> bool {
            a.units() > b.units()
        }

        #[pg_operator(immutable, parallel_safe, requires = [$concrete])]
        #[opname(>=)]
        #[commutator(<=)]
        #[negator(<)]
        #[restrict(scalargesel)]
        #[join(scalargejoinsel)]
        const fn $ge(a: $t, b: $t) -> bool {
            a.units() >= b.units()
        }

        // ARITHMETIC. Delegates to the same `kamu-money-core` kernels
        // `Money::checked_add` uses, so the SQL and Rust surfaces cannot
        // disagree about addition.
        //
        // The kernel returns `None` for an out-of-domain operand OR result. A
        // pinned value read from a column can be out of domain -- those bytes
        // came from disk -- so this arm stays. It is the one failure typing
        // cannot remove, because it is a fact about incoming data rather than
        // about this process.
        #[pg_operator(immutable, parallel_safe, requires = [$concrete])]
        #[opname(+)]
        #[commutator(+)]
        fn $add(a: $t, b: $t) -> $t {
            let Some(units) =
                kamu_money_core::advanced::arithmetic::add_units(a.units(), b.units())
            else {
                safe::raise::out_of_range(format!(
                    "{}: the result of + is outside the domain |units| <= 10^36 - 1",
                    <$t as safe::pinned::PinnedCurrency>::SQL_NAME
                ));
            };
            $t::from_payload(PinnedPayload::from_units(units))
        }

        #[pg_operator(immutable, parallel_safe, requires = [$concrete])]
        #[opname(-)]
        fn $sub(a: $t, b: $t) -> $t {
            let Some(units) =
                kamu_money_core::advanced::arithmetic::sub_units(a.units(), b.units())
            else {
                safe::raise::out_of_range(format!(
                    "{}: the result of - is outside the domain |units| <= 10^36 - 1",
                    <$t as safe::pinned::PinnedCurrency>::SQL_NAME
                ));
            };
            $t::from_payload(PinnedPayload::from_units(units))
        }

        /// The stable hash of a pinned value, folded to `int4`.
        ///
        /// Feeds `stable_hash` the currency from the TYPE and the units from the
        /// value, which is the same pair the erased type feeds it from its
        /// payload. So the two hash identically for the same logical amount, and
        /// `STABLE_HASH_VERSION` does not move even though the stored bytes
        /// narrowed from 18 to 16.
        ///
        /// There is no hash operator class here, for the same reason there is no
        /// btree one.
        #[pg_extern(immutable, parallel_safe, requires = [$concrete])]
        fn $hash(value: $t) -> i32 {
            // Validate before hashing, exactly as `kmoney_mixed_hash` does: a
            // corrupt stored value must raise here, not silently yield a stable
            // hash that downstream systems then persist.
            let amount = safe::payload::validate_pinned(value.payload()).unwrap_or_else(|e| {
                safe::raise::data_corrupted(format!(
                    "{}: {e}",
                    <$t as safe::pinned::PinnedCurrency>::SQL_NAME
                ))
            });
            kamu_money_core::advanced::stable_hash::fold_to_i32(
                kamu_money_core::advanced::stable_hash::stable_hash(
                    <<$t as safe::pinned::PinnedCurrency>::Currency
                        as kamu_money_core::StaticCurrency>::CODE
                        .numeric(),
                    amount.units(),
                ),
            )
        }

        // AGGREGATE. The transition state is a `bytea` carrying only the wide
        // accumulator.
        //
        // The erased aggregate's state appends the ISO code, and every one of
        // its three functions compares it: `accum` against the incoming row,
        // `combine` across two partials, and `final` resolves it before
        // returning. None of that survives here. The aggregate's argument type
        // names the currency, so a state that disagreed with the rows feeding it
        // cannot be built, and `"cannot sum X and Y: different currencies"` has
        // no occasion on which to occur.
        //
        // Non-strict, which is required rather than incidental: with no
        // `INITCOND` the state arrives NULL for the first row, and a strict
        // function would never be called to establish it.
        #[pg_extern(immutable, parallel_safe, requires = [$concrete])]
        fn $accum(state: Option<&[u8]>, value: Option<$t>) -> Option<Vec<u8>> {
            // A NULL row leaves the state as it was, so an all-NULL group
            // finishes NULL rather than a zero in a currency it never saw.
            let Some(value) = value else {
                return state.map(<[u8]>::to_vec);
            };
            let acc = match state {
                None => kamu_money_core::advanced::arithmetic::UnitSum::ZERO,
                Some(bytes) => safe::pinned::sum_state_decode::<$t>(bytes),
            };
            let acc = acc.add_units(value.units()).unwrap_or_else(|e| {
                safe::raise::out_of_range(format!(
                    "sum({}): {e}",
                    <$t as safe::pinned::PinnedCurrency>::SQL_NAME
                ))
            });
            Some(safe::pinned::sum_state_encode(acc))
        }

        /// Merge two partial states from parallel workers.
        ///
        /// Either side may be NULL -- a worker that scanned no rows produces no
        /// state -- so this is non-strict too. `UnitSum::merge` is associative
        /// and commutative, so which worker finished first cannot change the
        /// total.
        #[pg_extern(immutable, parallel_safe, requires = [$concrete])]
        fn $combine(left: Option<&[u8]>, right: Option<&[u8]>) -> Option<Vec<u8>> {
            let (left, right) = match (left, right) {
                (None, other) | (other, None) => return other.map(<[u8]>::to_vec),
                (Some(l), Some(r)) => (l, r),
            };
            let acc = safe::pinned::sum_state_decode::<$t>(left)
                .merge(safe::pinned::sum_state_decode::<$t>(right))
                .unwrap_or_else(|e| {
                    safe::raise::out_of_range(format!(
                        "sum({}): {e}",
                        <$t as safe::pinned::PinnedCurrency>::SQL_NAME
                    ))
                });
            Some(safe::pinned::sum_state_encode(acc))
        }

        /// One narrowing, one domain check.
        ///
        /// The erased counterpart also resolves a stored ISO code here and
        /// treats an unknown one as corruption. There is no code to resolve.
        #[pg_extern(immutable, parallel_safe, requires = [$concrete])]
        fn $final(state: Option<&[u8]>) -> Option<$t> {
            // No rows, or every row NULL: NULL, never a zero.
            let acc = safe::pinned::sum_state_decode::<$t>(state?);
            let total = acc.finish().unwrap_or_else(|e| {
                safe::raise::out_of_range(format!(
                    "sum({}): {e}",
                    <$t as safe::pinned::PinnedCurrency>::SQL_NAME
                ))
            });
            Some($t::from_payload(PinnedPayload::from_units(total)))
        }

        // SPLITTING. Both return their results in this same type, so a quotient
        // and its residue -- or every share of a distribution -- are in one
        // currency by construction. The erased forms resolve a stored ISO code
        // and carry it into each result instead.
        #[pg_extern(immutable, parallel_safe, requires = [$concrete])]
        fn $div(
            amount: $t,
            parts: i32,
            rounding: &str,
        ) -> TableIterator<'static, (name!(quotient, $t), name!(residue, $t))> {
            let (quotient, residue) = safe::pinned::divide_pinned(amount, parts, rounding);
            TableIterator::once((quotient, residue))
        }

        // `Array` by value: pgrx's `#[pg_extern]` ABI takes owned argument types
        // to build the SQL wrapper, so `needless_pass_by_value` cannot be honoured.
        #[allow(clippy::needless_pass_by_value)]
        #[pg_extern(immutable, parallel_safe, requires = [$concrete])]
        fn $allocate(amount: $t, weights: Array<'_, i32>) -> Vec<$t> {
            // The size cap reads the borrowed Array's len() BEFORE any element
            // is collected, so an array-bomb argument is refused before it can
            // allocate. Pinned by the unsafe_boundary hygiene test.
            safe::pinned::allocate_len_guard::<$t>(weights.len());
            let weights: Vec<Option<i32>> = weights.iter().collect();
            safe::pinned::allocate_pinned(amount, &weights)
        }
    };
}

// One per-currency type for every ISO 4217 code, derived from the register by
// `build.rs`. It also owns the single `bootstrap` block: pgrx permits only one,
// and every shell type -- including `kmoney_mixed`, which is not per-currency
// -- must be declared before the I/O functions that name it.
//
// Nothing is decided in the expansion. `build.rs` says what is derived and
// `pinned_money_type!` above says what is generated; between them there is no
// third place for a currency to be described differently.
include!(concat!(env!("OUT_DIR"), "/pinned_types.rs"));

fixed_length_money_type! {
    /// Money whose currency is **not** fixed by the column.
    ///
    /// 18 bytes on disk -- the pinned payload plus the ISO numeric code, because
    /// here the value is the only place the currency can live. A column may
    /// hold several currencies, and
    /// `SELECT sum(amount)` fails while the query is planned:
    ///
    /// ```text
    /// ERROR:  function sum(kmoney_mixed) does not exist
    /// ```
    ///
    /// Convert a value to its per-currency type through text: the pinned input
    /// function accepts the tagged form this type renders and refuses it when
    /// the tag names another currency.
    kmoney_mixed
}

// No `kmoney -> numeric` cast: egress keeps the exact currency-tagged text form
// instead of exposing PostgreSQL numeric arithmetic.

// Benchmark-only no-ops isolate pgrx wrapper cost (`rs_noop`) and the 16-byte
// `FromDatum` cost (`rs_noop_kmoney`) from function-body work.
#[cfg(feature = "boundary-probe")]
#[pg_extern(immutable, parallel_safe)]
fn rs_noop(x: i64) -> i64 {
    x
}

#[cfg(feature = "boundary-probe")]
#[pg_extern(immutable, parallel_safe, requires = ["kmoney_usd_concrete"])]
fn rs_noop_kmoney(m: kmoney_usd) -> i64 {
    // Returns a constant, not a property of `m`: the cost being measured is getting `m` across
    // the boundary at all. Reading a field would add a load to one side of the comparison.
    let _ = m;
    0
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    /// The payload is 18 bytes both in a tuple and as an expression, proving there is no
    /// varlena header.
    #[pg_test]
    fn kmoney_mixed_is_eighteen_bytes_with_no_header() {
        Spi::run("CREATE TABLE sized (v kmoney_mixed)").expect("table created");
        Spi::run("INSERT INTO sized VALUES ('USD 10.50')").expect("row inserted");

        let stored =
            Spi::get_one::<i32>("SELECT pg_column_size(v) FROM sized").expect("query ran").expect("not null");
        let in_memory = Spi::get_one::<i32>("SELECT pg_column_size('USD 10.50'::kmoney_mixed)")
            .expect("query ran")
            .expect("not null");

        assert_eq!(stored, 18, "the payload, with no varlena header");
        assert_eq!(
            in_memory, stored,
            "a fixed-length type has no in-memory header either; a varlena would read 22 here"
        );
    }

    /// PostgreSQL agrees it is fixed-length — the catalog, not just `pg_column_size`.
    ///
    /// `typlen` 18 and 16 (not `-1`), `typbyval = false` (both exceed 8, forcing pass-by-reference),
    /// `typalign = 'c'` and `typstorage = 'p'`. Exactly `uuid`'s shape, two bytes wider.
    #[pg_test]
    fn the_catalog_says_fixed_length_plain_and_byte_aligned() {
        let row = Spi::get_one::<String>(
            "SELECT string_agg(
                 format('%s=%s/%s/%s/%s', typname, typlen, typbyval, typalign, typstorage),
                 ',' ORDER BY typname
             )
               FROM pg_type WHERE typname IN ('kmoney_mixed', 'kmoney_usd')",
        )
        .expect("query ran")
        .expect("not null");
        // PostgreSQL renders booleans as t/f, so typbyval = false prints as "f".
        assert_eq!(row, "kmoney_mixed=18/f/c/p,kmoney_usd=16/f/c/p");
    }

    /// **`kmoney` is NOT smaller than `numeric(36,18)` for typical amounts.** Measured:
    ///
    /// | stored value          | `kmoney` | `numeric(36,18)` |
    /// |-----------------------|-----------:|-----------------:|
    /// | `0`                   |         18 |                3 |
    /// | `0.000000000000000001`|         18 |                5 |
    /// | `10.50`               |         18 |                7 |
    /// | domain top            |         18 |               23 |
    ///
    /// `numeric` is variable-width and drops trailing zeros, so it beats a fixed 18 bytes
    /// everywhere except the top of the domain — and even the top comparison flatters
    /// `kmoney`, since a real schema needs a currency column beside the `numeric` and this
    /// type carries its own in those 18 bytes.
    ///
    /// The type optimizes representation stability and exact ingress, not typical-value size.
    #[pg_test]
    fn the_size_tradeoff_against_numeric_is_measured_not_assumed() {
        Spi::run("CREATE TABLE compared (r kmoney_usd, n numeric(36,18))").expect("table created");
        Spi::run(
            "INSERT INTO compared VALUES
                 ('10.50', 10.50),
                 ('999999999999999999.999999999999999999',
                  999999999999999999.999999999999999999)",
        )
        .expect("rows inserted");

        let (typical_r, typical_n) = Spi::get_two::<i32, i32>(
            "SELECT pg_column_size(r), pg_column_size(n) FROM compared ORDER BY n LIMIT 1",
        )
        .expect("query ran");
        let (top_r, top_n) = Spi::get_two::<i32, i32>(
            "SELECT pg_column_size(r), pg_column_size(n) FROM compared ORDER BY n DESC LIMIT 1",
        )
        .expect("query ran");

        let (typical_r, typical_n) = (typical_r.expect("not null"), typical_n.expect("not null"));
        let (top_r, top_n) = (top_r.expect("not null"), top_n.expect("not null"));

        assert_eq!(typical_r, 16, "fixed width, whatever the value");
        assert_eq!(top_r, 16, "fixed width, whatever the value");

        assert!(
            typical_n < typical_r,
            "numeric is expected to WIN on a typical amount: numeric {typical_n} vs kmoney \
             {typical_r}. If this reverses, remeasure and update the documented tradeoff."
        );
        assert!(
            top_n > top_r,
            "at the domain top numeric should exceed the fixed width: numeric {top_n} vs \
             kmoney {top_r}"
        );
    }

    /// Size must not vary with the value. That is what "fixed-size, no limb codec" means, and
    /// it is the entire economic argument for a native type over `numeric`.
    #[pg_test]
    fn the_size_does_not_depend_on_the_value() {
        Spi::run("CREATE TABLE varied (v kmoney_mixed)").expect("table created");
        Spi::run(
            "INSERT INTO varied VALUES
                 ('USD 0.00'),
                 ('USD 10.50'),
                 ('IDR 999999999999999999.999999999999999999'),
                 ('JPY -1')",
        )
        .expect("rows inserted");

        let distinct = Spi::get_one::<i64>("SELECT count(DISTINCT pg_column_size(v)) FROM varied")
            .expect("query ran")
            .expect("not null");
        assert_eq!(distinct, 1, "every value must occupy the same space");
    }

    /// The text form round-trips through the database unchanged and matches
    /// `kamu_money_core`'s canonical rendering.
    #[pg_test]
    fn the_text_form_matches_money_core() {
        for (input, expected) in [
            ("USD 10.50", "USD 10.50"),
            ("USD 10.5", "USD 10.50"),  // liberal in, canonical out
            ("JPY 10.5", "JPY 10.5"),   // settles at 0dp
            ("KWD 10.5", "KWD 10.500"), // settles at 3dp
            ("USD -0.000000000000000001", "USD -0.000000000000000001"),
        ] {
            let got = Spi::get_one::<String>(&format!("SELECT '{input}'::kmoney_mixed::text"))
                .expect("query ran")
                .expect("not null");
            assert_eq!(got, expected, "input {input}");
        }
    }

    /// PostgreSQL `numeric(36,18)` rounds this over-precise value to zero.
    ///
    /// The refusal half is [`kmoney_refuses_what_numeric_silently_rounds`] below. They are two
    /// tests because a raised PostgreSQL `ERROR` longjmps out of `Spi`, aborting the
    /// transaction — so a single test cannot both observe a success and catch a failure, and
    /// `.is_err()` on `Spi::get_one` never gets the chance to be false.
    #[pg_test]
    fn numeric_silently_rounds_four_e_minus_nineteen_to_zero() {
        let rounded = Spi::get_one::<bool>("SELECT '0.0000000000000000004'::numeric(36,18) = 0")
            .expect("query ran")
            .expect("not null");
        assert!(rounded, "numeric(36,18) rounds 4e-19 to zero");
    }

    /// `kmoney` refuses exactly what `numeric(36,18)` swallows.
    ///
    /// This is the difference an input function makes: it runs BEFORE any coercion, where a
    /// `CHECK` or `DOMAIN` runs after and is handed the already-altered value.
    // The expected message is one long line on purpose: pgrx parses this attribute by taking
    // the literal's source text and running it through an `unescape` pass, so a `\`-newline
    // continuation is not reliably folded away and would be compared verbatim.
    #[pg_test(
        error = "kmoney_usd: 19 fractional digits exceeds the supported scale of 18, in \"0.0000000000000000004\""
    )]
    fn kmoney_refuses_what_numeric_silently_rounds() {
        Spi::get_one::<String>("SELECT '0.0000000000000000004'::kmoney_usd::text").ok();
    }

    /// The top of the domain is representable — the bound is `<=`, not `<`.
    #[pg_test]
    fn the_domain_top_round_trips() {
        let top = Spi::get_one::<String>("SELECT '999999999999999999.999999999999999999'::kmoney_idr::text")
            .expect("query ran")
            .expect("not null");
        assert_eq!(top, "999999999999999999.999999999999999999");
    }

    /// One major unit past the domain is refused by the same check `kamu_money_core` applies.
    #[pg_test(
        error = "kmoney_idr: 1000000000000000000000000000000000000 canonical units is outside the supported range -999999999999999999999999999999999999..=999999999999999999999999999999999999, in \"1000000000000000000\""
    )]
    fn one_unit_past_the_domain_is_refused() {
        Spi::get_one::<String>("SELECT '1000000000000000000'::kmoney_idr::text").ok();
    }

    /// A currency `kamu_money_core` does not know is refused at input, not stored and guessed at
    /// later. There is exactly one currency table, in `kamu_money_core`.
    #[pg_test(error = "kmoney_mixed: invalid money literal, in \"ZWL 1.00\"")]
    fn an_unknown_currency_is_refused_at_the_boundary() {
        Spi::get_one::<String>("SELECT 'ZWL 1.00'::kmoney_mixed::text").ok();
    }

    /// Native and text storage must expose the same canonical representation.
    ///
    /// Both columns are written from the SAME literal here, and the assertion is that
    /// `kmoney`'s output function reproduces the text form exactly. Divergence would make the
    /// portable and native columns return different representations for the same amount.
    #[pg_test]
    fn the_native_type_and_the_text_storage_agree() {
        Spi::run(
            "CREATE TABLE both_forms (
                 portable text  NOT NULL,
                 native kmoney_mixed NOT NULL
             )",
        )
        .expect("table created");

        // One literal, both columns. The text column takes it verbatim; the mixed column
        // parses it through this extension's input function.
        for literal in [
            "USD 10.50",
            "JPY 10.5",
            "KWD 10.500",
            "IDR 999999999999999999.999999999999999999",
            "USD -0.000000000000000001",
            "XAU 10.5",
        ] {
            Spi::run(&format!("INSERT INTO both_forms VALUES ('{literal}', '{literal}')"))
                .unwrap_or_else(|e| panic!("insert {literal}: {e}"));
        }

        // Rendering the native column back must reproduce the stored text, for every row.
        let disagreements =
            Spi::get_one::<i64>("SELECT count(*) FROM both_forms WHERE portable <> native::text")
                .expect("query ran")
                .expect("not null");
        assert_eq!(disagreements, 0, "the text storage and the native type must render identically");

        // And the reverse direction: text parsed into the native type equals the native value.
        let mismatches = Spi::get_one::<i64>(
            "SELECT count(*) FROM both_forms WHERE portable::kmoney_mixed::text <> native::text",
        )
        .expect("query ran")
        .expect("not null");
        assert_eq!(mismatches, 0, "text -> kmoney_mixed -> text must be the identity");
    }

    #[pg_test(error = "cannot cast type kmoney_usd to numeric")]
    fn there_is_no_cast_to_numeric() {
        Spi::get_one::<String>("SELECT ('1.00'::kmoney_usd)::numeric::text").ok();
    }

    // ---------------------------------------------------------------------
    // Per-currency types. These assert the wire claim the shape exists for.
    // ---------------------------------------------------------------------

    /// The column's type is the currency, so egress carries no tag.
    #[pg_test]
    fn a_pinned_type_renders_bare() {
        let rendered =
            Spi::get_one::<String>("SELECT '10.50'::kmoney_usd::text").expect("query ran").expect("not null");
        assert_eq!(
            rendered, "10.50",
            "the currency is the type; repeating it in the text would restate the catalog"
        );
    }

    /// The tag is optional, and checked when present.
    #[pg_test]
    fn a_pinned_type_accepts_its_own_tag() {
        let rendered = Spi::get_one::<String>("SELECT 'USD 10.50'::kmoney_usd::text")
            .expect("query ran")
            .expect("not null");
        assert_eq!(rendered, "10.50");
    }

    /// THE wire claim: a well-formed value of another currency is refused, not
    /// reinterpreted. Without this check the digits would simply be accepted.
    #[pg_test(error = "kmoney_usd: expected USD, got IDR")]
    fn a_pinned_type_refuses_another_currencys_tag() {
        Spi::run("SELECT 'IDR 10.50'::kmoney_usd").expect("should have failed");
    }

    /// THE calculation claim: cross-currency arithmetic has no operator to
    /// resolve, so it fails while the query is parsed rather than inside an
    /// operator that had to check.
    #[pg_test(error = "operator does not exist: kmoney_usd + kmoney_idr")]
    fn cross_currency_arithmetic_has_no_operator() {
        Spi::run("SELECT '1.00'::kmoney_usd + '1.00'::kmoney_idr").expect("should have failed");
    }

    /// The currency left the value, so the payload is two bytes narrower than
    /// the erased type still carrying an ISO code.
    #[pg_test]
    fn a_pinned_value_is_sixteen_bytes() {
        let pinned = Spi::get_one::<i32>("SELECT pg_column_size('10.50'::kmoney_usd)")
            .expect("query ran")
            .expect("not null");
        let erased = Spi::get_one::<i32>("SELECT pg_column_size('USD 10.50'::kmoney_mixed)")
            .expect("query ran")
            .expect("not null");
        assert_eq!(pinned, 16, "units only, with no varlena header");
        assert_eq!(erased, 18, "the erased type still stores the ISO code beside them");
    }

    /// Every code in the register got a type, not merely the ones anyone tried.
    #[pg_test]
    fn every_iso_code_has_a_type() {
        let generated = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_type WHERE typname LIKE 'kmoney\\_%' AND typlen = 16",
        )
        .expect("query ran")
        .expect("not null");
        assert_eq!(
            usize::try_from(generated).expect("a count fits usize"),
            kamu_money_core::Iso4217::EVERY.len(),
            "the manifest is derived from the register, so the counts cannot disagree"
        );
    }

    /// Ordering is TOTAL within a pinned type.
    ///
    /// The SQL type fixes the currency, so the operator has nothing to check
    /// and nothing to refuse: the question a currency check would answer cannot
    /// be asked. `kmoney_mixed` registers no ordering at all, for the converse
    /// reason — it carries a currency the comparison would have to reconcile.
    #[pg_test]
    fn pinned_ordering_needs_no_currency_check() {
        let ordered = Spi::get_one::<bool>("SELECT '1.00'::kmoney_usd < '2.00'::kmoney_usd")
            .expect("query ran")
            .expect("not null");
        assert!(ordered, "within one currency, ordering is just units");
    }

    /// And the comparison it would have refused has no operator to reach.
    #[pg_test(error = "operator does not exist: kmoney_usd < kmoney_idr")]
    fn cross_currency_ordering_has_no_operator() {
        Spi::run("SELECT '1.00'::kmoney_usd < '1.00'::kmoney_idr").expect("should have failed");
    }

    #[pg_test]
    fn pinned_arithmetic_stays_within_the_currency() {
        let sum = Spi::get_one::<String>("SELECT ('1.25'::kmoney_usd + '2.75'::kmoney_usd)::text")
            .expect("query ran")
            .expect("not null");
        assert_eq!(sum, "4.00");
    }

    /// A pinned value hashes exactly as the erased one does for the same logical
    /// amount.
    ///
    /// This is why `STABLE_HASH_VERSION` did not move when the payload narrowed
    /// from 18 bytes to 16: both feed `stable_hash` the same `(code, units)`
    /// pair, the pinned type from its *type* and the erased one from its
    /// *payload*. The storage width changed; the hashed value did not.
    #[pg_test]
    fn a_pinned_value_hashes_as_the_erased_one_does() {
        let pinned = Spi::get_one::<i32>("SELECT kmoney_usd_hash('10.50'::kmoney_usd)")
            .expect("query ran")
            .expect("not null");
        let erased = Spi::get_one::<i32>("SELECT kmoney_mixed_hash('USD 10.50'::kmoney_mixed)")
            .expect("query ran")
            .expect("not null");
        assert_eq!(pinned, erased, "same amount, same stable hash, whatever the storage width");
    }

    /// No generated type carries a btree or hash operator class.
    ///
    /// Their absence is not an omission. It is the one surface `YugabyteDB`'s
    /// planner will not resolve for a custom type, and removing it is what makes
    /// these types byte-exact there. An opclass added later would break that for
    /// every currency at once, so the assertion covers all of them.
    #[pg_test]
    fn no_generated_type_carries_an_operator_class() {
        // BOTH families: a mixed-type opclass would cost byte-exactness the
        // same way, so the 18-byte type is inspected alongside the 178.
        let classes = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_opclass WHERE opcintype IN \
             (SELECT oid FROM pg_type WHERE typname LIKE 'kmoney\\_%' AND typlen IN (16, 18))",
        )
        .expect("query ran")
        .expect("not null");
        // Prove the query looked at something before believing its zero. A
        // count assertion that expects 0 passes identically when the predicate
        // matches nothing, so an escaping slip in the LIKE pattern would
        // silently disarm this test -- which is exactly what happened once.
        let inspected = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_type WHERE typname LIKE 'kmoney\\_%' AND typlen IN (16, 18)",
        )
        .expect("query ran")
        .expect("not null");
        assert_eq!(
            usize::try_from(inspected).expect("a count fits usize"),
            kamu_money_core::Iso4217::EVERY.len().saturating_add(1),
            "the opclass count below means nothing unless this matched every generated type \
             plus kmoney_mixed"
        );

        assert_eq!(classes, 0, "an operator class here would cost YugabyteDB byte-exactness");

        // An opclass is not the only door: a loose `pg_amop` operator-family
        // member is enough to hand the planner a merge or hash strategy. The
        // catalog must hold no strategy row that names a money type on either
        // side.
        let amops = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_amop WHERE amoplefttype IN \
             (SELECT oid FROM pg_type WHERE typname LIKE 'kmoney\\_%' AND typlen IN (16, 18)) \
             OR amoprighttype IN \
             (SELECT oid FROM pg_type WHERE typname LIKE 'kmoney\\_%' AND typlen IN (16, 18))",
        )
        .expect("query ran")
        .expect("not null");
        assert_eq!(amops, 0, "a loose operator-family member would enable planner strategies");
    }

    /// `sum()` totals a pinned column.
    #[pg_test]
    fn sum_totals_a_pinned_column() {
        Spi::run("CREATE TABLE ledger (amount kmoney_usd)").expect("table created");
        Spi::run("INSERT INTO ledger VALUES ('1.25'), ('2.75'), ('6.00')").expect("rows inserted");

        let total = Spi::get_one::<String>("SELECT sum(amount)::text FROM ledger")
            .expect("query ran")
            .expect("not null");
        assert_eq!(total, "10.00");
    }

    /// An empty group has no currency-free zero to return, so it is NULL -- the
    /// same answer `sum()` gives for every built-in type.
    #[pg_test]
    fn sum_of_no_rows_is_null() {
        Spi::run("CREATE TABLE empty_ledger (amount kmoney_usd)").expect("table created");

        let total = Spi::get_one::<String>("SELECT sum(amount)::text FROM empty_ledger").expect("query ran");
        assert!(total.is_none(), "no rows means no currency to carry, so no zero to return");
    }

    /// Every pinned type has its own `sum()`.
    ///
    /// So no aggregate accepts two currencies, and a cross-currency total is not
    /// something a query can ask for. The erased type has to refuse one at run
    /// time instead -- the same difference the operators show, one layer up.
    #[pg_test]
    fn every_pinned_type_has_its_own_sum() {
        // Joined on `prorettype`, a plain `oid` column, rather than on
        // `proargtypes[0]`: subscripting an `oidvector` in a join condition
        // silently matched nothing.
        let aggregates = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_aggregate a \
               JOIN pg_proc p ON p.oid = a.aggfnoid \
               JOIN pg_type t ON t.oid = p.prorettype \
              WHERE p.proname = 'sum' AND t.typlen = 16 AND t.typname LIKE 'kmoney\\_%'",
        )
        .expect("query ran")
        .expect("not null");
        assert_eq!(
            usize::try_from(aggregates).expect("a count fits usize"),
            kamu_money_core::Iso4217::EVERY.len(),
            "one aggregate per currency, from the same register the types came from"
        );
    }

    /// Division returns a quotient and a residue that reconstruct the input.
    ///
    /// Both arrive as the same type, so "quotient in one currency, residue in
    /// another" is not a state this can produce -- the conservation check below
    /// is therefore about *amounts* only, which is the whole point.
    #[pg_test]
    fn division_conserves_the_pinned_amount() {
        let (quotient, residue) = Spi::get_two::<String, String>(
            "SELECT quotient::text, residue::text FROM kmoney_usd_div('10.00'::kmoney_usd, 3, 'toward_zero')",
        )
        .expect("query ran");
        let quotient = quotient.expect("not null");
        let residue = residue.expect("not null");
        assert_eq!(quotient, "3.333333333333333333");
        assert_eq!(residue, "0.000000000000000001");

        let rebuilt = Spi::get_one::<bool>(
            "SELECT q.quotient + q.quotient + q.quotient + q.residue = '10.00'::kmoney_usd \
               FROM kmoney_usd_div('10.00'::kmoney_usd, 3, 'toward_zero') q",
        )
        .expect("query ran")
        .expect("not null");
        assert!(rebuilt, "parts x quotient + residue must reconstruct the input exactly");
    }

    /// Allocation distributes across weights and conserves the total.
    #[pg_test]
    fn allocation_conserves_the_pinned_total() {
        let total = Spi::get_one::<String>(
            "SELECT sum(share)::text FROM unnest(\
                 kmoney_usd_allocate('10.00'::kmoney_usd, ARRAY[1, 1, 1])\
             ) AS share",
        )
        .expect("query ran")
        .expect("not null");
        assert_eq!(total, "10.00", "every unit lands in exactly one share");
    }

    // ---------------------------------------------------------------------
    // Ported from the erased type's battery. Same properties, no currency
    // checks left to exercise -- those questions are no longer askable.
    // ---------------------------------------------------------------------

    /// The stable hash pinned to exact numbers -- the on-disk contract.
    ///
    /// These are the SAME constants the erased type pinned: the hash feeds
    /// `stable_hash(code, units)`, and the pinned type supplies the code from
    /// its type where the erased one read it from its payload. A change here
    /// needs a `STABLE_HASH_VERSION` bump and a re-hash of any store that
    /// persisted these values, not a re-blessed constant.
    #[pg_test]
    fn the_persisted_hash_values_are_pinned_not_merely_consistent() {
        for (expression, expected) in [
            ("kmoney_usd_hash('0.00'::kmoney_usd)", 702_888_007_i32),
            ("kmoney_usd_hash('1.00'::kmoney_usd)", -1_388_235_877),
            ("kmoney_idr_hash('1.00'::kmoney_idr)", -129_968_833),
            ("kmoney_usd_hash('-1.00'::kmoney_usd)", 1_671_845_669),
        ] {
            let got = Spi::get_one::<i32>(&format!("SELECT {expression}")).expect("query ran").expect("row");
            assert_eq!(got, expected, "{expression} changed; that breaks every persisted use");
        }
    }

    /// Addition is exact at one unit of the eighteenth decimal.
    #[pg_test]
    fn addition_is_exact_at_one_unit_of_the_eighteenth_decimal() {
        let sum = Spi::get_one::<String>(
            "SELECT ('0.000000000000000001'::kmoney_usd + '0.000000000000000002'::kmoney_usd)::text",
        )
        .expect("query ran")
        .expect("row");
        assert_eq!(sum, "0.000000000000000003");
    }

    /// One unit past the domain top is refused by the same kernel Rust uses.
    #[pg_test(error = "kmoney_idr: the result of + is outside the domain |units| <= 10^36 - 1")]
    fn addition_past_the_domain_top_is_refused() {
        Spi::get_one::<String>(
            "SELECT ('999999999999999999.999999999999999999'::kmoney_idr
                   + '0.000000000000000001'::kmoney_idr)::text",
        )
        .ok();
    }

    /// `[top, top, -top]` totals correctly whatever order rows arrive in: the
    /// wide accumulator makes the transient excursion representable.
    #[pg_test]
    fn the_sum_aggregate_is_plan_independent_across_a_domain_edge_transient() {
        Spi::run("CREATE TABLE edge (position int, amount kmoney_usd)").expect("table created");
        Spi::run(
            "INSERT INTO edge VALUES
                 (1, '999999999999999999.999999999999999999'),
                 (2, '999999999999999999.999999999999999999'),
                 (3, '-999999999999999999.999999999999999999')",
        )
        .expect("rows inserted");
        for order in ["position", "position DESC"] {
            let total = Spi::get_one::<String>(&format!(
                "SELECT sum(amount)::text FROM (SELECT amount FROM edge ORDER BY {order}) ordered",
            ))
            .expect("query ran")
            .expect("row");
            assert_eq!(total, "999999999999999999.999999999999999999", "order {order}");
        }
    }

    /// A partial from a worker that scanned no rows merges as the identity.
    #[pg_test]
    fn the_sum_aggregate_combines_an_empty_partial() {
        let total = Spi::get_one::<String>(
            "SELECT kmoney_usd_sum_final(
                 kmoney_usd_sum_combine(NULL, kmoney_usd_sum_accum(NULL, '1.25'::kmoney_usd))
             )::text",
        )
        .expect("query ran")
        .expect("row");
        assert_eq!(total, "1.25");
    }

    /// The state type is `bytea`, so the functions are callable by hand with
    /// arbitrary bytes. A forged state must be an error, not a misread.
    #[pg_test(error = "sum(kmoney_usd): transition state must be exactly 32 bytes, got 5")]
    fn the_sum_aggregate_rejects_a_forged_transition_state() {
        Spi::get_one::<String>("SELECT kmoney_usd_sum_final('\\x0102030405'::bytea)::text").ok();
    }

    /// A total past the domain is refused at `finish`, not stored.
    #[pg_test(
        error = "sum(kmoney_usd): 1000000000000000000000000000000000000 canonical units is outside the supported range -999999999999999999999999999999999999..=999999999999999999999999999999999999"
    )]
    fn the_sum_aggregate_rejects_a_total_that_leaves_the_domain() {
        Spi::run("CREATE TABLE overflowing (amount kmoney_usd)").expect("table created");
        Spi::run(
            "INSERT INTO overflowing VALUES
                 ('999999999999999999.999999999999999999'),
                 ('0.000000000000000001')",
        )
        .expect("rows inserted");
        Spi::get_one::<String>("SELECT sum(amount)::text FROM overflowing").ok();
    }

    /// The refusal above narrows to `i128` first, so it reports `OutOfDomain`. This one cannot:
    /// 171 rows at the domain edge exceed `i128` itself, which is the `WideOutOfDomain` arm and
    /// the only path where the accumulator's exact total has to survive a width it cannot be
    /// narrowed into. 170 rows still narrow, so 171 is the threshold rather than a round number.
    #[pg_test(
        error = "sum(kmoney_usd): 170999999999999999999999999999999999829 canonical units is outside the supported range -999999999999999999999999999999999999..=999999999999999999999999999999999999"
    )]
    fn the_sum_aggregate_reports_a_total_too_wide_for_i128() {
        Spi::run("CREATE TABLE too_wide (amount kmoney_usd)").expect("table created");
        Spi::run(
            "INSERT INTO too_wide
                 SELECT '999999999999999999.999999999999999999'::kmoney_usd
                   FROM generate_series(1, 171)",
        )
        .expect("rows inserted");
        Spi::get_one::<String>("SELECT sum(amount)::text FROM too_wide").ok();
    }

    /// The mixed type still has no aggregate: a column of several currencies
    /// has no total, and the refusal is at plan time.
    #[pg_test(error = "function sum(kmoney_mixed) does not exist")]
    fn sum_on_a_mixed_column_fails_at_plan_time() {
        Spi::run("CREATE TABLE mixed_sum (amount kmoney_mixed)").expect("table created");
        Spi::get_one::<String>("SELECT sum(amount)::text FROM mixed_sum").ok();
    }

    /// Every rounding mode satisfies `parts x quotient + residue = input`.
    #[pg_test]
    fn the_division_identity_holds_for_every_rounding_mode() {
        for mode in [
            "half_even",
            "half_away_from_zero",
            "half_toward_zero",
            "toward_zero",
            "away_from_zero",
            "floor",
            "ceil",
        ] {
            let holds = Spi::get_one::<bool>(&format!(
                "SELECT q.quotient + q.quotient + q.quotient + q.residue = '-10.00'::kmoney_usd
                   FROM kmoney_usd_div('-10.00'::kmoney_usd, 3, '{mode}') q",
            ))
            .expect("query ran")
            .expect("row");
            assert!(holds, "identity failed under {mode}");
        }
    }

    /// Under a round-up mode the residue of a positive amount is NEGATIVE: the
    /// identity `q*n + residue = amount` fixes its sign, and a ledger posting
    /// "leftover" as a nonnegative line item would mis-sign the entry.
    #[pg_test]
    fn the_residue_is_negative_under_round_up_modes() {
        let row = Spi::get_one::<String>(
            "SELECT quotient::text || ' | ' || residue::text \
               FROM kmoney_usd_div('10.00'::kmoney_usd, 3, 'ceil')",
        )
        .expect("query ran")
        .expect("row");
        assert_eq!(row, "3.333333333333333334 | -0.000000000000000002");
    }

    #[pg_test(
        error = "kmoney_usd_div: \"bankers\" is not a rounding mode; expected one of: half_even, half_away_from_zero, half_toward_zero, toward_zero, away_from_zero, floor, ceil"
    )]
    fn division_refuses_an_unknown_rounding_mode() {
        Spi::get_one::<String>(
            "SELECT quotient::text FROM kmoney_usd_div('10.00'::kmoney_usd, 3, 'bankers')",
        )
        .ok();
    }

    /// Uneven weights conserve the total; leftover units land on the FIRST
    /// positive-weight shares, not on the largest remainders.
    ///
    /// That distinction is frozen contract: 8 units over `[1, 1, 3]` is
    /// `[2, 2, 4]` here, while Hamilton/largest-remainder would say
    /// `[2, 1, 5]`. A reconciler implementing the wrong scheme flags a
    /// phantom one-unit leak, so the scheme itself must be pinned by an
    /// inexact division -- the exact case below cannot tell them apart.
    #[pg_test]
    fn allocation_honours_weights_and_still_conserves() {
        let shares = Spi::get_one::<String>(
            "SELECT string_agg(share::text, ',')
               FROM unnest(kmoney_usd_allocate('0.10'::kmoney_usd, ARRAY[3, 1, 1])) AS share",
        )
        .expect("query ran")
        .expect("row");
        assert_eq!(shares, "0.06,0.02,0.02");

        let first_positive = Spi::get_one::<String>(
            "SELECT string_agg(share::text, ',')
               FROM unnest(kmoney_usd_allocate('0.000000000000000008'::kmoney_usd, ARRAY[1, 1, 3])) \
               AS share",
        )
        .expect("query ran")
        .expect("row");
        assert_eq!(
            first_positive, "0.000000000000000002,0.000000000000000002,0.000000000000000004",
            "leftover units go to the first positive-weight shares"
        );
    }

    /// A refund allocates by the same scheme: every share carries the amount's
    /// sign, and the leftover (negative) units land on the same first
    /// positive-weight shares.
    #[pg_test]
    fn a_negative_amount_allocates_by_the_same_scheme() {
        let exact = Spi::get_one::<String>(
            "SELECT string_agg(share::text, ',')
               FROM unnest(kmoney_usd_allocate('-0.10'::kmoney_usd, ARRAY[3, 1, 1])) AS share",
        )
        .expect("query ran")
        .expect("row");
        assert_eq!(exact, "-0.06,-0.02,-0.02");

        let inexact = Spi::get_one::<String>(
            "SELECT string_agg(share::text, ',')
               FROM unnest(kmoney_usd_allocate('-0.000000000000000008'::kmoney_usd, ARRAY[1, 1, 3])) \
               AS share",
        )
        .expect("query ran")
        .expect("row");
        assert_eq!(inexact, "-0.000000000000000002,-0.000000000000000002,-0.000000000000000004");
    }

    /// A zero weight receives an explicit zero share, never a unit.
    ///
    /// Allocation is exact at canonical units, not at the display scale: 0.03
    /// over weights [1, 0, 1] splits into two shares of 0.015 with no
    /// remainder, and the zero-weight recipient still appears, at zero.
    #[pg_test]
    fn allocation_never_pays_a_zero_weight_recipient() {
        let shares = Spi::get_one::<String>(
            "SELECT string_agg(share::text, ',')
               FROM unnest(kmoney_usd_allocate('0.03'::kmoney_usd, ARRAY[1, 0, 1])) AS share",
        )
        .expect("query ran")
        .expect("row");
        assert_eq!(shares, "0.015,0.00,0.015");
    }

    #[pg_test(error = "kmoney_usd_allocate: NULL weight -- a share of nothing is not a share of zero")]
    fn allocation_refuses_a_null_weight() {
        Spi::get_one::<String>(
            "SELECT count(*)::text FROM unnest(kmoney_usd_allocate('1.00'::kmoney_usd, ARRAY[1, NULL]))",
        )
        .ok();
    }

    #[pg_test(error = "kmoney_usd_allocate: weights sum to zero -- the amount would have nowhere to go")]
    fn allocation_refuses_weights_that_sum_to_zero() {
        Spi::get_one::<String>(
            "SELECT count(*)::text FROM unnest(kmoney_usd_allocate('1.00'::kmoney_usd, ARRAY[0, 0]))",
        )
        .ok();
    }

    // -------------------------------------------------------------------
    // The SQLSTATE contract. `#[pg_test(error = ...)]` pins message TEXT;
    // these pin the CODE a client dispatches on -- retry and classification
    // layers read SQLSTATE, not prose, and a refusal that arrived as XX000
    // would page internal-error monitoring for a data error. The regress
    // twin (12-errors) pins the same codes as psql-visible output.
    // -------------------------------------------------------------------

    /// True only when `sql` fails with exactly `code`; any other error
    /// propagates and fails the test.
    fn refused_with(sql: &str, code: pgrx::pg_sys::errcodes::PgSqlErrorCode) -> bool {
        pgrx::PgTryBuilder::new(|| {
            Spi::run(sql).ok();
            false
        })
        .catch_when(code, |_| true)
        .execute()
    }

    #[pg_test]
    fn a_wrong_tag_refusal_is_invalid_text_representation() {
        assert!(
            refused_with(
                "SELECT 'IDR 1.00'::kmoney_usd",
                pgrx::pg_sys::errcodes::PgSqlErrorCode::ERRCODE_INVALID_TEXT_REPRESENTATION
            ),
            "a wrong currency tag must be SQLSTATE 22P02, and must be refused at all"
        );
    }

    #[pg_test]
    fn an_out_of_domain_literal_refusal_is_numeric_value_out_of_range() {
        assert!(
            refused_with(
                "SELECT '1000000000000000000.00'::kmoney_usd",
                pgrx::pg_sys::errcodes::PgSqlErrorCode::ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE
            ),
            "a magnitude past the domain top must be SQLSTATE 22003, matching numeric's class"
        );
    }

    #[pg_test]
    fn a_forged_sum_state_refusal_is_invalid_binary_representation() {
        assert!(
            refused_with(
                "SELECT kmoney_usd_sum_final('\\x0102030405'::bytea)",
                pgrx::pg_sys::errcodes::PgSqlErrorCode::ERRCODE_INVALID_BINARY_REPRESENTATION
            ),
            "a transition state of the wrong width must be SQLSTATE 22P03"
        );
    }

    #[pg_test]
    fn a_zero_parts_division_refusal_is_division_by_zero() {
        assert!(
            refused_with(
                "SELECT quotient::text FROM kmoney_usd_div('1.00'::kmoney_usd, 0, 'floor')",
                pgrx::pg_sys::errcodes::PgSqlErrorCode::ERRCODE_DIVISION_BY_ZERO
            ),
            "dividing into zero parts must be SQLSTATE 22012"
        );
    }

    #[pg_test]
    fn an_invalid_weights_refusal_is_invalid_parameter_value() {
        assert!(
            refused_with(
                "SELECT kmoney_usd_allocate('1.00'::kmoney_usd, ARRAY[]::int4[])",
                pgrx::pg_sys::errcodes::PgSqlErrorCode::ERRCODE_INVALID_PARAMETER_VALUE
            ),
            "an empty weight vector must be SQLSTATE 22023"
        );
    }

    #[pg_test]
    fn a_cross_currency_expression_refusal_is_undefined_function() {
        assert!(
            refused_with(
                "SELECT '1.00'::kmoney_usd + '1.00'::kmoney_idr",
                pgrx::pg_sys::errcodes::PgSqlErrorCode::ERRCODE_UNDEFINED_FUNCTION
            ),
            "a cross-currency expression must fail to parse as SQLSTATE 42883 -- PostgreSQL's \
             code, raised because no operator exists to resolve"
        );
    }
}

/// Required by `cargo pgrx test`.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}
