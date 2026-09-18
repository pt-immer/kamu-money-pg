//! Pgrx-free tests for the exact payload codec used by the extension.

#[path = "../../kamu-money-pg/src/safe/payload.rs"]
mod payload;

use kamu_money_core::Iso4217;
use kamu_money_core::advanced::domain::DOMAIN_MAX;
use payload::{
    OutOfDomain, PAYLOAD_BYTES, PINNED_PAYLOAD_BYTES, Payload, PinnedPayload, ValidationError,
    validate_payload, validate_pinned,
};

#[test]
fn payload_layout_and_little_endian_round_trip() {
    assert_eq!(size_of::<Payload>(), PAYLOAD_BYTES);
    assert_eq!(align_of::<Payload>(), 1);

    for (units, code) in [(0, 840), (i128::MIN, u16::MIN), (i128::MAX, u16::MAX)] {
        let payload = Payload::from_parts(units, code);
        assert_eq!(payload.units(), units);
        assert_eq!(payload.code(), code);
        assert_eq!(&payload.to_bytes()[..16], &units.to_le_bytes());
        assert_eq!(&payload.to_bytes()[16..], &code.to_le_bytes());
        assert_eq!(Payload::try_from(payload.to_bytes().as_slice()), Ok(payload));
    }
}

#[test]
fn payload_slice_conversion_requires_exact_width() {
    assert_eq!(Payload::try_from(&[0_u8; PAYLOAD_BYTES - 1][..]).unwrap_err().actual, 17);
    assert_eq!(Payload::try_from(&[0_u8; PAYLOAD_BYTES + 1][..]).unwrap_err().actual, 19);
}

#[test]
fn validation_checks_code_assignment_and_domain() {
    // No expected-currency parameter: a type with an expectation carries it in
    // the catalog and stores no code, so only the erased payload reaches here.
    let usd = Iso4217::from_alpha3("USD").expect("USD is assigned");

    let valid = validate_payload(Payload::from_parts(1, usd.numeric())).expect("valid USD");
    assert_eq!(valid.payload(), Payload::from_parts(1, usd.numeric()));
    assert_eq!(valid.units(), 1);
    assert_eq!(valid.currency(), usd);

    assert_eq!(
        validate_payload(Payload::from_parts(1, 0)),
        Err(ValidationError::UnknownCurrency { code: 0 })
    );
    assert!(matches!(
        validate_payload(Payload::from_parts(DOMAIN_MAX + 1, usd.numeric())),
        Err(ValidationError::OutOfDomain { units, currency }) if units == DOMAIN_MAX + 1 && currency == usd
    ));
    assert!(matches!(
        validate_payload(Payload::from_parts(-DOMAIN_MAX - 1, usd.numeric())),
        Err(ValidationError::OutOfDomain { units, currency }) if units == -DOMAIN_MAX - 1 && currency == usd
    ));
}

// ---------------------------------------------------------------------------
// The pinned payload: units alone, currency in the catalog.
// ---------------------------------------------------------------------------

#[test]
fn pinned_payload_layout_and_little_endian_round_trip() {
    assert_eq!(size_of::<PinnedPayload>(), PINNED_PAYLOAD_BYTES);
    assert_eq!(align_of::<PinnedPayload>(), 1);

    for units in [0, 1, -1, DOMAIN_MAX, -DOMAIN_MAX, i128::MIN, i128::MAX] {
        let payload = PinnedPayload::from_units(units);
        assert_eq!(payload.units(), units);
        assert_eq!(payload.to_bytes(), units.to_le_bytes());
        assert_eq!(PinnedPayload::from_bytes(payload.to_bytes()), payload);
    }
}

/// The whole payload is the number. There is no code beside it that could
/// contradict the column's type, which is the reason the width is 16 and not 18.
#[test]
fn a_pinned_payload_is_exactly_the_amount() {
    assert_eq!(size_of::<PinnedPayload>(), size_of::<i128>());
    assert_eq!(
        PINNED_PAYLOAD_BYTES + 2,
        PAYLOAD_BYTES,
        "the two bytes are the ISO code the mixed type still stores"
    );
}

/// Out-of-domain is the ONLY way a pinned payload can be wrong: the bytes come
/// off disk or the wire, so this check cannot be typed away, while the two
/// currency-shaped failures the mixed codec reports are unconstructible here.
#[test]
fn validate_pinned_admits_exactly_the_domain() {
    assert_eq!(validate_pinned(PinnedPayload::from_units(0)).map(|a| a.units()), Ok(0));
    assert_eq!(validate_pinned(PinnedPayload::from_units(DOMAIN_MAX)).map(|a| a.units()), Ok(DOMAIN_MAX));
    assert_eq!(validate_pinned(PinnedPayload::from_units(-DOMAIN_MAX)).map(|a| a.units()), Ok(-DOMAIN_MAX));

    assert_eq!(validate_pinned(PinnedPayload::from_units(i128::MAX)), Err(OutOfDomain { units: i128::MAX }));
    assert_eq!(validate_pinned(PinnedPayload::from_units(i128::MIN)), Err(OutOfDomain { units: i128::MIN }));
}
