//! PostgreSQL ABI boundary.
//!
//! # The width contract
//!
//! This crate registers two families of fixed-width type, and they are **not**
//! the same width. Nothing here may assume a single payload size.
//!
//! | Family | `INTERNALLENGTH` | Payload |
//! | --- | --- | --- |
//! | per-currency `kmoney_<code>` | 16 | units only; the currency is the SQL type |
//! | `kmoney_mixed` | 18 | units plus a stored ISO numeric code |
//!
//! Each is registered pass-by-reference, byte-aligned (`ALIGNMENT = char`) and
//! `STORAGE = plain`. For a given registered OID a non-null `Datum` therefore
//! points to at least **that type's own width** in readable bytes; array
//! elements use the same representation. Every unsafe read below is licensed by
//! that guarantee *for the OID it is reached through*, which is why the reads
//! are generated per family against that family's width constant rather than
//! sharing one.
//!
//! Each Rust struct is bound to its declaration by `const` assertions on
//! `size_of` and `align_of`, so a declaration that drifted from its struct
//! fails to compile instead of mis-reading a datum.
//!
//! pgrx invokes the ABI traits only for these SQL types. PostgreSQL errors may
//! escape through pgrx's panic machinery, so no critical cleanup is delegated
//! to a destructor after an error.

mod datum;
mod wire;

/// Re-exported so `pinned_money_type!` can reach it from the crate root, where
/// the per-currency types are defined.
pub(crate) use datum::impl_pinned_datum;

/// Emit PostgreSQL's V1 calling-convention record for one raw symbol.
macro_rules! pg_finfo_v1 {
    ($name:ident, $finfo:ident) => {
        static $name: pgrx::pg_sys::Pg_finfo_record = pgrx::pg_sys::Pg_finfo_record { api_version: 1 };

        #[unsafe(no_mangle)]
        pub extern "C" fn $finfo() -> *const pgrx::pg_sys::Pg_finfo_record {
            &raw const $name
        }
    };
}

pg_finfo_v1!(FINFO_MIXED_RECV, pg_finfo_kmoney_mixed_recv);
pg_finfo_v1!(FINFO_PINNED_RECV, pg_finfo_kmoney_pinned_recv);
