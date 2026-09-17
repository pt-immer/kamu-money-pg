//! Derive one PostgreSQL type per ISO 4217 code from the register.
//!
//! ```text
//! vendor/list-one.xml -> kamu-money-core's register -> this manifest -> macros -> code
//!       (data)                  (enum + markers)        (declensions)     (shape)
//! ```
//!
//! The manifest is **derived**, not maintained beside the register, so it cannot
//! drift from it. There is nothing to verify here because there is no second
//! list that could disagree with the first.
//!
//! # What lives here rather than in the macro
//!
//! Two things a `macro_rules!` cannot do:
//!
//! * **Declension.** It can neither lowercase nor concatenate identifiers, so it
//!   cannot turn `USD` into `kmoney_usd` or `kmoney_usd_out`. Every name a
//!   generated type needs is derived here and passed in already formed.
//! * **DDL.** `extension_sql!` parses its first argument as a string *literal*,
//!   so `CREATE TYPE` text cannot be composed with `concat!` at the macro level.
//!   It has to arrive as a literal, which only a generator can produce.
//!
//! Everything else -- the struct, the sealed impl, the datum ABI, the three I/O
//! functions -- is shape, and shape belongs to `pinned_money_type!`, where one
//! definition governs every currency and none can differ from it.

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

use kamu_money_core::Iso4217;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    let mut shells = String::from("CREATE TYPE kmoney_mixed;\n");
    let mut types = String::new();

    for code in Iso4217::EVERY {
        let alpha3 = code.alpha3();
        let lower = alpha3.to_lowercase();
        let ty = format!("kmoney_{lower}");
        // Every identifier the macro needs, declined here because a
        // `macro_rules!` cannot build one.
        let f_in = format!("{ty}_in");
        let f_out = format!("{ty}_out");
        let f_send = format!("{ty}_send");
        let f_recv = format!("{ty}_recv");
        let f_hash = format!("{ty}_hash");
        let (eq, ne) = (format!("{ty}_eq"), format!("{ty}_ne"));
        let (lt, le) = (format!("{ty}_lt"), format!("{ty}_le"));
        let (gt, ge) = (format!("{ty}_gt"), format!("{ty}_ge"));
        let (add, sub) = (format!("{ty}_add"), format!("{ty}_sub"));
        let accum = format!("{ty}_sum_accum");
        let combine = format!("{ty}_sum_combine");
        let finalize = format!("{ty}_sum_final");
        let div = format!("{ty}_div");
        let allocate = format!("{ty}_allocate");

        writeln!(shells, "CREATE TYPE {ty};").expect("writing to a String cannot fail");

        write!(
            types,
            r#"
pinned_money_type! {{
    /// {name} ({alpha3}): 16 bytes, canonical units, no currency in the value.
    ///
    /// The column's type is the currency, so `'10.50'::{ty}` needs no tag and a
    /// cross-currency expression has no operator to resolve at all.
    {ty}: kamu_money_core::iso::{alpha3},
    concrete = "{ty}_concrete",
    io = [{f_in}, {f_out}, {f_send}],
    cmp = [{eq}, {ne}, {lt}, {le}, {gt}, {ge}],
    arith = [{add}, {sub}],
    agg = [{accum}, {combine}, {finalize}],
    split = [{div}, {allocate}],
    hash = {f_hash},
}}

extension_sql!(
    r"
CREATE FUNCTION {f_recv}(internal) RETURNS {ty}
    AS 'MODULE_PATHNAME', 'kmoney_pinned_recv'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE {ty} (
    INTERNALLENGTH = 16,
    INPUT          = {f_in},
    OUTPUT         = {f_out},
    SEND           = {f_send},
    RECEIVE        = {f_recv},
    ALIGNMENT      = char,
    STORAGE        = plain
);
",
    name = "{ty}_concrete",
    requires = [{f_send}, "money_shell_types", {f_in}, {f_out}],
);

extension_sql!(
    r"
CREATE AGGREGATE sum({ty}) (
    SFUNC       = {accum},
    STYPE       = bytea,
    COMBINEFUNC = {combine},
    FINALFUNC   = {finalize},
    PARALLEL    = SAFE
);
",
    name = "{ty}_sum_aggregate",
    requires = ["{ty}_concrete", {accum}, {combine}, {finalize}],
);
"#,
            name = code.name(),
        )
        .expect("writing to a String cannot fail");
    }

    // pgrx permits exactly one `bootstrap` block, and a shell type must exist
    // before the I/O functions that name it. So every shell in the extension is
    // declared here, including the two that are not per-currency.
    let manifest = format!(
        "// @generated from the ISO 4217 register by build.rs. Do not edit.\n\
         extension_sql!(\n    r\"\n{shells}\",\n    name = \"money_shell_types\",\n    bootstrap\n);\n{types}"
    );

    let out = PathBuf::from(env::var("OUT_DIR").expect("cargo sets OUT_DIR")).join("pinned_types.rs");
    fs::write(&out, manifest).expect("the manifest must be writable");
}
