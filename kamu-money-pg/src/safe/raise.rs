//! Refusals that carry their SQLSTATE.
//!
//! pgrx's `error!` hardcodes `ERRCODE_INTERNAL_ERROR` (`XX000`), which tells a
//! client "extension bug, should never happen" for what is actually a data
//! error it can act on. Each helper here raises the SQLSTATE class a client is
//! entitled to dispatch on, so retry and classification layers work without
//! matching message text. The codes are part of the frozen wire contract,
//! pinned by the `12-errors` regress suite.
//!
//! `XX001 data_corrupted` is deliberately still an internal class: it fires
//! only when bytes already stored in a column fail validation, which really is
//! a "should never happen" for monitoring to page on.

use pgrx::pg_sys::errcodes::PgSqlErrorCode;
use pgrx::pg_sys::panic::ErrorReport;

/// Raise `message` with `code`, aborting the transaction.
fn raise(code: PgSqlErrorCode, message: String) -> ! {
    ErrorReport::new(code, message, "kamu-money-pg").report(pgrx::pg_sys::elog::PgLogLevel::ERROR);
    unreachable!("report(ERROR) does not return");
}

/// `22P02 invalid_text_representation`: text input this type refuses.
pub(crate) fn invalid_text(message: String) -> ! {
    raise(PgSqlErrorCode::ERRCODE_INVALID_TEXT_REPRESENTATION, message)
}

/// `22003 numeric_value_out_of_range`: a value or result outside the domain.
pub(crate) fn out_of_range(message: String) -> ! {
    raise(PgSqlErrorCode::ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE, message)
}

/// `22P03 invalid_binary_representation`: bytes that do not denote a value.
pub(crate) fn invalid_binary(message: String) -> ! {
    raise(PgSqlErrorCode::ERRCODE_INVALID_BINARY_REPRESENTATION, message)
}

/// `XX001 data_corrupted`: stored bytes failed validation on the way out.
pub(crate) fn data_corrupted(message: String) -> ! {
    raise(PgSqlErrorCode::ERRCODE_DATA_CORRUPTED, message)
}

/// `22023 invalid_parameter_value`: an argument no call may pass.
pub(crate) fn invalid_parameter(message: String) -> ! {
    raise(PgSqlErrorCode::ERRCODE_INVALID_PARAMETER_VALUE, message)
}

/// `22012 division_by_zero`: dividing into zero parts.
pub(crate) fn division_by_zero(message: String) -> ! {
    raise(PgSqlErrorCode::ERRCODE_DIVISION_BY_ZERO, message)
}
