//! Pure codec and validation for the PostgreSQL payloads.
//!
//! Two widths, because there are two kinds of type:
//!
//! * [`PinnedPayload`] — 16 bytes, canonical units alone, for a type whose
//!   currency is the SQL type itself and therefore lives in the catalog.
//!   Storing a code beside the amount would store a fact the catalog already
//!   guarantees, and one that could then contradict it.
//! * [`Payload`] — 18 bytes, units plus an ISO numeric code, for a
//!   deliberately currency-erased type whose column may hold several
//!   currencies.
//!
//! The widths differ, so nothing may assume a single `PAYLOAD_BYTES`.

use core::fmt;

use kamu_money_core::Iso4217;
use kamu_money_core::advanced::domain;

/// Bytes in the fixed-width PostgreSQL and binary-wire representation.
pub(crate) const PAYLOAD_BYTES: usize = 18;

/// Raw storage bytes: 16 little-endian amount bytes, then a little-endian ISO code.
///
/// A `Payload` is structural, not semantic. Call [`validate_payload`] before
/// treating its bytes as money.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(transparent)]
pub(crate) struct Payload([u8; PAYLOAD_BYTES]);

const _: () = assert!(size_of::<Payload>() == PAYLOAD_BYTES);
const _: () = assert!(align_of::<Payload>() == 1);

impl Payload {
    pub(crate) fn from_parts(units: i128, code: u16) -> Self {
        let mut bytes = [0_u8; PAYLOAD_BYTES];
        bytes[..16].copy_from_slice(&units.to_le_bytes());
        bytes[16..].copy_from_slice(&code.to_le_bytes());
        Self(bytes)
    }

    pub(crate) const fn from_bytes(bytes: [u8; PAYLOAD_BYTES]) -> Self {
        Self(bytes)
    }

    pub(crate) const fn to_bytes(self) -> [u8; PAYLOAD_BYTES] {
        self.0
    }

    pub(crate) fn units(self) -> i128 {
        let mut units = [0_u8; 16];
        units.copy_from_slice(&self.0[..16]);
        i128::from_le_bytes(units)
    }

    pub(crate) const fn code(self) -> u16 {
        u16::from_le_bytes([self.0[16], self.0[17]])
    }
}

impl TryFrom<&[u8]> for Payload {
    type Error = PayloadLengthError;

    fn try_from(bytes: &[u8]) -> Result<Self, Self::Error> {
        let bytes: [u8; PAYLOAD_BYTES] =
            bytes.try_into().map_err(|_| PayloadLengthError { actual: bytes.len() })?;
        Ok(Self::from_bytes(bytes))
    }
}

// ---------------------------------------------------------------------------
// The pinned payload: units alone, currency in the catalog.
// ---------------------------------------------------------------------------

/// Bytes in a per-currency type's fixed-width representation.
pub(crate) const PINNED_PAYLOAD_BYTES: usize = 16;

/// Raw storage bytes for a pinned type: 16 little-endian amount bytes.
///
/// Structural, not semantic — call [`validate_pinned`] before treating the
/// bytes as money. Unlike [`Payload`] there is no code to resolve, so the only
/// question left is whether the units are in the domain.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(transparent)]
pub(crate) struct PinnedPayload([u8; PINNED_PAYLOAD_BYTES]);

const _: () = assert!(size_of::<PinnedPayload>() == PINNED_PAYLOAD_BYTES);
const _: () = assert!(align_of::<PinnedPayload>() == 1);

impl PinnedPayload {
    pub(crate) const fn from_units(units: i128) -> Self {
        Self(units.to_le_bytes())
    }

    pub(crate) const fn from_bytes(bytes: [u8; PINNED_PAYLOAD_BYTES]) -> Self {
        Self(bytes)
    }

    pub(crate) const fn to_bytes(self) -> [u8; PINNED_PAYLOAD_BYTES] {
        self.0
    }

    /// The whole payload is the number, so this is a total conversion.
    ///
    /// `const`, unlike [`Payload::units`], which has to copy a subslice out of
    /// a wider array before it can decode one.
    pub(crate) const fn units(self) -> i128 {
        i128::from_le_bytes(self.0)
    }
}

/// Units known to be inside the money domain.
///
/// Carries no currency: `C` carries it at the type level, so there is no second
/// copy that could disagree with the column it was read from.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct PinnedAmount(i128);

impl PinnedAmount {
    pub(crate) const fn units(self) -> i128 {
        self.0
    }
}

/// The only way a pinned payload can be wrong.
///
/// A single struct rather than an enum: [`ValidationError`]'s other two
/// variants describe a stored currency code, and a pinned type stores none.
/// The currency is deliberately absent here too — the caller knows it
/// statically and can name it in the message without this type carrying it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct OutOfDomain {
    pub(crate) units: i128,
}

impl fmt::Display for OutOfDomain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "stored amount with {} units is outside the domain |units| <= 10^36 - 1", self.units)
    }
}

/// Validate a pinned payload read from disk or off the wire.
///
/// # Errors
/// [`OutOfDomain`] when the units fall outside the money domain. That check
/// cannot be typed away: the bytes are untrusted input, not a value this
/// process constructed.
pub(crate) const fn validate_pinned(payload: PinnedPayload) -> Result<PinnedAmount, OutOfDomain> {
    let units = payload.units();
    if domain::in_domain(units) { Ok(PinnedAmount(units)) } else { Err(OutOfDomain { units }) }
}

// ---------------------------------------------------------------------------
// The mixed payload: units plus a stored ISO code.
// ---------------------------------------------------------------------------

/// A payload whose stored currency and amount domain are valid.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ValidatedAmount {
    payload: Payload,
    currency: Iso4217,
}

impl ValidatedAmount {
    pub(crate) const fn payload(self) -> Payload {
        self.payload
    }

    pub(crate) fn units(self) -> i128 {
        self.payload.units()
    }

    pub(crate) const fn currency(self) -> Iso4217 {
        self.currency
    }
}

/// Validate one raw payload at every mixed, wire, and datum-to-operation edge.
///
/// There is no `expected` currency parameter. The erased type stores a code
/// precisely because no expectation exists for it, and every type that HAS an
/// expectation carries it in the catalog and stores no code at all.
pub(crate) fn validate_payload(payload: Payload) -> Result<ValidatedAmount, ValidationError> {
    let currency = Iso4217::from_numeric(payload.code())
        .ok_or(ValidationError::UnknownCurrency { code: payload.code() })?;
    if !domain::in_domain(payload.units()) {
        return Err(ValidationError::OutOfDomain { units: payload.units(), currency });
    }

    Ok(ValidatedAmount { payload, currency })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct PayloadLengthError {
    pub(crate) actual: usize,
}

impl fmt::Display for PayloadLengthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "payload is {} bytes; expected {PAYLOAD_BYTES}", self.actual)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ValidationError {
    UnknownCurrency { code: u16 },
    OutOfDomain { units: i128, currency: Iso4217 },
}

impl fmt::Display for ValidationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::UnknownCurrency { code } => {
                write!(f, "stored ISO 4217 numeric code {code} is not in kamu_money_core's table")
            }
            Self::OutOfDomain { units, currency } => {
                write!(
                    f,
                    "stored {} amount with {units} units is outside the domain |units| <= 10^36 - 1",
                    currency.alpha3()
                )
            }
        }
    }
}
