//! I/O, equality, and checked conversion for `kmoney_mixed`.
//!
//! The type has no arithmetic or ordering surface. `sum(kmoney_mixed)` fails
//! during query planning; conversion to a per-currency type goes through the
//! text form, whose pinned input function proves the tag before accepting it.

use super::{kmoney_mixed, raise, validated_or_error};
use kamu_money_core::errors::ParseMoneyError;
use kamu_money_core::text;
use pgrx::prelude::*;

#[pg_extern(immutable, parallel_safe, requires = ["money_shell_types"])]
fn kmoney_mixed_in(input: &core::ffi::CStr) -> kmoney_mixed {
    let text = match input.to_str() {
        Ok(t) => t,
        Err(e) => raise::invalid_text(format!("kmoney_mixed: input is not valid UTF-8: {e}")),
    };
    match text::parse(text) {
        Ok((currency, units)) => kmoney_mixed::new(units, currency.numeric()),
        // The same SQLSTATE split as the pinned parser: out-of-domain
        // magnitudes are `22003`, everything the grammar refuses is `22P02`.
        Err(e @ ParseMoneyError::Amount(_)) => raise::out_of_range(format!("kmoney_mixed: {e}, in {text:?}")),
        Err(e) => raise::invalid_text(format!("kmoney_mixed: {e}, in {text:?}")),
    }
}

#[doc(hidden)]
#[pg_extern(immutable, parallel_safe, requires = ["money_shell_types"])]
fn kmoney_mixed_out(value: kmoney_mixed) -> alloc::ffi::CString {
    let amount = validated_or_error(value.payload(), "kmoney_mixed");
    let rendered = text::render(amount.units(), amount.currency()).unwrap_or_else(|e| {
        raise::data_corrupted(format!("kmoney_mixed: stored amount cannot be rendered: {e}"))
    });
    alloc::ffi::CString::new(rendered)
        .unwrap_or_else(|e| error!("kmoney_mixed: rendered form contains a NUL byte: {e}"))
}

extension_sql!(
    r"
CREATE FUNCTION kmoney_mixed_recv(internal) RETURNS kmoney_mixed
    AS 'MODULE_PATHNAME', 'kmoney_mixed_recv'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE kmoney_mixed (
    INTERNALLENGTH = 18,
    INPUT          = kmoney_mixed_in,
    OUTPUT         = kmoney_mixed_out,
    SEND           = kmoney_mixed_send,
    RECEIVE        = kmoney_mixed_recv,
    ALIGNMENT      = char,
    STORAGE        = plain
);
",
    name = "kmoney_mixed_concrete",
    requires = [kmoney_mixed_send, "money_shell_types", kmoney_mixed_in, kmoney_mixed_out],
);

// Equality is total and currency-aware. No operator class is registered, so
// these operators are predicates only: no value index, grouping, uniqueness,
// or ordering. Cast through text to a per-currency type before arithmetic or
// ordering; that type's input function refuses a tag it does not carry.

#[pg_operator(immutable, parallel_safe, requires = ["kmoney_mixed_concrete"])]
#[opname(=)]
#[commutator(=)]
#[negator(<>)]
#[restrict(eqsel)]
#[join(eqjoinsel)]
fn kmoney_mixed_eq(a: kmoney_mixed, b: kmoney_mixed) -> bool {
    a.code() == b.code() && a.units() == b.units()
}

#[pg_operator(immutable, parallel_safe, requires = ["kmoney_mixed_concrete"])]
#[opname(<>)]
#[commutator(<>)]
#[negator(=)]
#[restrict(neqsel)]
#[join(neqjoinsel)]
fn kmoney_mixed_ne(a: kmoney_mixed, b: kmoney_mixed) -> bool {
    !kmoney_mixed_eq(a, b)
}

/// Return the stable payload hash folded to `int4`.
///
/// The mixed type has no hash operator class. A per-currency type hashes the
/// same logical amount to the same value even though the payloads differ in
/// width, because both feed `stable_hash` the currency and the units.
#[pg_extern(immutable, parallel_safe, requires = ["kmoney_mixed_concrete"])]
fn kmoney_mixed_hash(value: kmoney_mixed) -> i32 {
    let amount = validated_or_error(value.payload(), "kmoney_mixed");
    kamu_money_core::advanced::stable_hash::fold_to_i32(kamu_money_core::advanced::stable_hash::stable_hash(
        amount.currency().numeric(),
        amount.units(),
    ))
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use super::kmoney_mixed;
    use pgrx::prelude::*;

    /// Equality is currency-aware and remains a non-indexed predicate.
    #[pg_test]
    fn a_mixed_column_equality_is_currency_aware_and_never_raises() {
        Spi::run("CREATE TABLE mixed_eq (amount kmoney_mixed)").expect("table created");
        Spi::run("INSERT INTO mixed_eq VALUES ('USD 1.00'), ('IDR 1.00'), ('USD 1.00'), ('USD 2.00')")
            .expect("rows inserted");

        let same = Spi::get_one::<bool>("SELECT 'USD 1.00'::kmoney_mixed = 'IDR 1.00'::kmoney_mixed")
            .expect("query ran")
            .expect("row");
        assert!(!same, "same number, different currency, different money");

        let n = Spi::get_one::<i64>("SELECT count(*) FROM mixed_eq WHERE amount = 'USD 1.00'::kmoney_mixed")
            .expect("query ran")
            .expect("row");
        assert_eq!(n, 2, "two USD 1.00 rows match; IDR 1.00 and USD 2.00 do not");
    }

    /// Mixed values have no cross-currency ordering.
    #[pg_test(error = "operator does not exist: kmoney_mixed < kmoney_mixed")]
    fn a_mixed_column_cannot_be_ordered() {
        Spi::get_one::<bool>("SELECT 'USD 1.00'::kmoney_mixed < 'USD 2.00'::kmoney_mixed").ok();
    }

    #[pg_test(error = "operator does not exist: kmoney_mixed + kmoney_mixed")]
    fn addition_on_the_mixed_type_does_not_exist_either() {
        Spi::get_one::<String>("SELECT ('USD 1.00'::kmoney_mixed + 'USD 1.00'::kmoney_mixed)::text").ok();
    }

    /// Mixed values store and render several currencies.
    #[pg_test]
    fn a_mixed_column_stores_several_currencies_side_by_side() {
        Spi::run("CREATE TABLE mixed_ok (amount kmoney_mixed)").expect("table created");
        Spi::run("INSERT INTO mixed_ok VALUES ('USD 1.00'), ('IDR 16000.00'), ('JPY 150')")
            .expect("rows inserted");

        let rendered = Spi::get_one::<String>(
            "SELECT string_agg(amount::text, ', ' ORDER BY amount::text) FROM mixed_ok",
        )
        .expect("query ran")
        .expect("not null");
        assert_eq!(rendered, "IDR 16000.00, JPY 150, USD 1.00");
    }

    /// Conversion succeeds when the expected currency matches.
    #[pg_test]
    fn the_conversion_out_of_mixed_proves_the_currency() {
        // Through text: the mixed type renders its tag, and the pinned input
        // function accepts the tagged form only when the tag matches its type.
        let got = Spi::get_one::<String>("SELECT ('USD 2.50'::kmoney_mixed)::text::kmoney_usd::text")
            .expect("query ran")
            .expect("not null");
        assert_eq!(got, "2.50", "the pinned form needs no tag; the column's type is the currency");
    }

    #[pg_test(error = "kmoney_usd: expected USD, got IDR")]
    fn the_conversion_out_of_mixed_refuses_the_wrong_currency() {
        Spi::get_one::<String>("SELECT ('IDR 2.50'::kmoney_mixed)::text::kmoney_usd::text").ok();
    }

    /// Corrupt stored units cannot escape through the text conversion path:
    /// the mixed OUTPUT function validates before rendering, so the pinned
    /// input function never sees them.
    #[pg_test(
        error = "kmoney_mixed: stored USD amount with 1000000000000000000000000000000000000 units is outside the domain |units| <= 10^36 - 1"
    )]
    fn the_conversion_out_of_mixed_refuses_corrupt_units() {
        let corrupt = kmoney_mixed::new(kamu_money_core::advanced::domain::DOMAIN_MAX + 1, 840);
        let _ = super::kmoney_mixed_out(corrupt);
    }
}
