//! Safe semantic layer over the raw PostgreSQL payload and ABI.

pub(crate) mod payload;
pub(crate) mod pinned;
pub(crate) mod raise;

use crate::kmoney_mixed;
use payload::{Payload, ValidatedAmount, validate_payload};

mod mixed;

/// Validate a stored payload before safe semantic code consumes it.
///
/// `XX001 data_corrupted`: the bytes came from a column, so a failure here is
/// stored corruption, not a data error the client caused.
pub(crate) fn validated_or_error(payload: Payload, context: &str) -> ValidatedAmount {
    validate_payload(payload).unwrap_or_else(|error| raise::data_corrupted(format!("{context}: {error}")))
}
