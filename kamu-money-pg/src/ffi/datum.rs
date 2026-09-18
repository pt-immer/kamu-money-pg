//! Fixed-width PostgreSQL datum ownership and ABI traits.

use pgrx::datum::{FromDatum, IntoDatum};

use crate::kmoney_mixed;
use crate::safe::payload::{PAYLOAD_BYTES, Payload};

macro_rules! impl_fixed_length_datum {
    ($t:ident) => {
        impl IntoDatum for $t {
            fn into_datum(self) -> Option<pgrx::pg_sys::Datum> {
                let payload = self.payload().to_bytes();

                // SAFETY: a PostgreSQL backend has a valid CurrentMemoryContext.
                // `palloc` returns at least PAYLOAD_BYTES writable bytes or raises.
                let dst = unsafe { pgrx::pg_sys::palloc(PAYLOAD_BYTES).cast::<u8>() };
                // SAFETY: source and destination are distinct and each spans
                // PAYLOAD_BYTES. PostgreSQL owns and later releases `dst`.
                unsafe {
                    core::ptr::copy_nonoverlapping(payload.as_ptr(), dst, PAYLOAD_BYTES);
                }
                Some(dst.into())
            }

            fn type_oid() -> pgrx::pg_sys::Oid {
                pgrx::wrappers::rust_regtypein::<Self>()
            }
        }

        impl FromDatum for $t {
            unsafe fn from_polymorphic_datum(
                datum: pgrx::pg_sys::Datum,
                is_null: bool,
                _typoid: pgrx::pg_sys::Oid,
            ) -> Option<Self> {
                if is_null {
                    return None;
                }
                // SAFETY: the shared ABI contract in `ffi` guarantees a non-null
                // datum for this OID points to PAYLOAD_BYTES readable bytes.
                // Alignment is one, and the bytes are copied out immediately.
                let bytes = unsafe { datum.cast_mut_ptr::<u8>().cast::<[u8; PAYLOAD_BYTES]>().read() };
                Some(Self::from_payload(Payload::from_bytes(bytes)))
            }
        }

        // SAFETY: registered arrays store each non-null element by reference
        // using the same fixed-width, byte-aligned representation as scalars.
        unsafe impl pgrx::datum::UnboxDatum for $t {
            type As<'src> = $t;

            unsafe fn unbox<'src>(datum: pgrx::datum::Datum<'src>) -> Self::As<'src>
            where
                Self: 'src,
            {
                // SAFETY: `UnboxDatum` is called for a non-null element of the
                // registered SQL type; the ABI contract guarantees 18 readable bytes.
                let bytes = unsafe { datum.sans_lifetime().cast_mut_ptr::<[u8; PAYLOAD_BYTES]>().read() };
                Self::from_payload(Payload::from_bytes(bytes))
            }
        }

        // SAFETY: the literal SQL mapping names the exact registered fixed-width
        // type implemented by this Rust representation.
        unsafe impl pgrx::pgrx_sql_entity_graph::metadata::SqlTranslatable for $t {
            const TYPE_IDENT: &'static str = stringify!($t);
            const TYPE_ORIGIN: pgrx::pgrx_sql_entity_graph::metadata::TypeOrigin =
                pgrx::pgrx_sql_entity_graph::metadata::TypeOrigin::External;
            const ARGUMENT_SQL: Result<
                pgrx::pgrx_sql_entity_graph::metadata::SqlMappingRef,
                pgrx::pgrx_sql_entity_graph::metadata::ArgumentError,
            > = Ok(pgrx::pgrx_sql_entity_graph::metadata::SqlMappingRef::literal(stringify!($t)));
            const RETURN_SQL: Result<
                pgrx::pgrx_sql_entity_graph::metadata::ReturnsRef,
                pgrx::pgrx_sql_entity_graph::metadata::ReturnsError,
            > = Ok(pgrx::pgrx_sql_entity_graph::metadata::ReturnsRef::One(
                pgrx::pgrx_sql_entity_graph::metadata::SqlMappingRef::literal(stringify!($t)),
            ));
        }

        // SAFETY: pgrx calls this implementation only for arguments whose SQL
        // metadata maps to this registered by-reference type.
        unsafe impl<'fcx> pgrx::callconv::ArgAbi<'fcx> for $t {
            unsafe fn unbox_arg_unchecked(arg: pgrx::callconv::Arg<'_, 'fcx>) -> Self {
                let index = arg.index();
                // SAFETY: the trait caller guarantees `arg` has this SQL type.
                unsafe {
                    arg.unbox_arg_using_from_datum()
                        .unwrap_or_else(|| panic!("argument {index} must not be null"))
                }
            }

            unsafe fn unbox_nullable_arg(
                arg: pgrx::callconv::Arg<'_, 'fcx>,
            ) -> pgrx::nullable::Nullable<Self> {
                // SAFETY: the trait caller guarantees `arg` has this SQL type;
                // this pgrx helper preserves its nullable state.
                unsafe { arg.unbox_arg_using_from_datum() }.into()
            }
        }

        // SAFETY: pgrx requests this return mapping only for the registered SQL
        // type, and `IntoDatum` allocates in PostgreSQL's current memory context.
        unsafe impl pgrx::callconv::BoxRet for $t {
            unsafe fn box_into<'fcx>(
                self,
                fcinfo: &mut pgrx::callconv::FcInfo<'fcx>,
            ) -> pgrx::datum::Datum<'fcx> {
                match self.into_datum() {
                    Some(datum) => {
                        // SAFETY: `datum` was allocated by this type's `IntoDatum`
                        // implementation for the current PostgreSQL call.
                        unsafe { fcinfo.return_raw_datum(datum) }
                    }
                    None => fcinfo.return_null(),
                }
            }
        }
    };
}

impl_fixed_length_datum!(kmoney_mixed);

/// The same ABI surface for a per-currency type, over the 16-byte payload.
///
/// Separate from [`impl_fixed_length_datum`] rather than parameterised by width
/// because the two differ in what a datum *means*, not only in how long it is:
/// a pinned datum carries no currency code, so it holds nothing that could
/// resolve to a currency other than its column's.
macro_rules! impl_pinned_datum {
    ($t:ident) => {
        impl IntoDatum for $t {
            fn into_datum(self) -> Option<pgrx::pg_sys::Datum> {
                let payload = self.payload().to_bytes();

                // SAFETY: a PostgreSQL backend has a valid CurrentMemoryContext.
                // `palloc` returns at least PINNED_PAYLOAD_BYTES writable bytes or raises.
                let dst = unsafe { pgrx::pg_sys::palloc(PINNED_PAYLOAD_BYTES).cast::<u8>() };
                // SAFETY: source and destination are distinct and each spans
                // PINNED_PAYLOAD_BYTES. PostgreSQL owns and later releases `dst`.
                unsafe {
                    core::ptr::copy_nonoverlapping(payload.as_ptr(), dst, PINNED_PAYLOAD_BYTES);
                }
                Some(dst.into())
            }

            fn type_oid() -> pgrx::pg_sys::Oid {
                pgrx::wrappers::rust_regtypein::<Self>()
            }
        }

        impl FromDatum for $t {
            unsafe fn from_polymorphic_datum(
                datum: pgrx::pg_sys::Datum,
                is_null: bool,
                _typoid: pgrx::pg_sys::Oid,
            ) -> Option<Self> {
                if is_null {
                    return None;
                }
                // SAFETY: the width contract in `ffi` guarantees a non-null datum for
                // this OID points to PINNED_PAYLOAD_BYTES readable bytes. Alignment is
                // one, and the bytes are copied out immediately.
                let bytes = unsafe { datum.cast_mut_ptr::<u8>().cast::<[u8; PINNED_PAYLOAD_BYTES]>().read() };
                Some(Self::from_payload(PinnedPayload::from_bytes(bytes)))
            }
        }

        // SAFETY: registered arrays store each non-null element by reference
        // using the same fixed-width, byte-aligned representation as scalars.
        unsafe impl pgrx::datum::UnboxDatum for $t {
            type As<'src> = $t;

            unsafe fn unbox<'src>(datum: pgrx::datum::Datum<'src>) -> Self::As<'src>
            where
                Self: 'src,
            {
                let ptr = datum.sans_lifetime().cast_mut_ptr::<[u8; PINNED_PAYLOAD_BYTES]>();
                // SAFETY: `UnboxDatum` is called for a non-null element of the registered
                // SQL type; the width contract guarantees PINNED_PAYLOAD_BYTES readable bytes.
                let bytes = unsafe { ptr.read() };
                Self::from_payload(PinnedPayload::from_bytes(bytes))
            }
        }

        // SAFETY: the literal SQL mapping names the exact registered fixed-width
        // type implemented by this Rust representation.
        unsafe impl pgrx::pgrx_sql_entity_graph::metadata::SqlTranslatable for $t {
            const TYPE_IDENT: &'static str = stringify!($t);
            const TYPE_ORIGIN: pgrx::pgrx_sql_entity_graph::metadata::TypeOrigin =
                pgrx::pgrx_sql_entity_graph::metadata::TypeOrigin::External;
            const ARGUMENT_SQL: Result<
                pgrx::pgrx_sql_entity_graph::metadata::SqlMappingRef,
                pgrx::pgrx_sql_entity_graph::metadata::ArgumentError,
            > = Ok(pgrx::pgrx_sql_entity_graph::metadata::SqlMappingRef::literal(stringify!($t)));
            const RETURN_SQL: Result<
                pgrx::pgrx_sql_entity_graph::metadata::ReturnsRef,
                pgrx::pgrx_sql_entity_graph::metadata::ReturnsError,
            > = Ok(pgrx::pgrx_sql_entity_graph::metadata::ReturnsRef::One(
                pgrx::pgrx_sql_entity_graph::metadata::SqlMappingRef::literal(stringify!($t)),
            ));
        }

        // SAFETY: pgrx calls this implementation only for arguments whose SQL
        // metadata maps to this registered by-reference type.
        unsafe impl<'fcx> pgrx::callconv::ArgAbi<'fcx> for $t {
            unsafe fn unbox_arg_unchecked(arg: pgrx::callconv::Arg<'_, 'fcx>) -> Self {
                let index = arg.index();
                // SAFETY: the trait caller guarantees `arg` has this SQL type.
                unsafe {
                    arg.unbox_arg_using_from_datum()
                        .unwrap_or_else(|| panic!("argument {index} must not be null"))
                }
            }

            unsafe fn unbox_nullable_arg(
                arg: pgrx::callconv::Arg<'_, 'fcx>,
            ) -> pgrx::nullable::Nullable<Self> {
                // SAFETY: the trait caller guarantees `arg` has this SQL type;
                // this pgrx helper preserves its nullable state.
                unsafe { arg.unbox_arg_using_from_datum() }.into()
            }
        }

        // SAFETY: pgrx requests this return mapping only for the registered SQL
        // type, and `IntoDatum` allocates in PostgreSQL's current memory context.
        unsafe impl pgrx::callconv::BoxRet for $t {
            unsafe fn box_into<'fcx>(
                self,
                fcinfo: &mut pgrx::callconv::FcInfo<'fcx>,
            ) -> pgrx::datum::Datum<'fcx> {
                match self.into_datum() {
                    Some(datum) => {
                        // SAFETY: `datum` was allocated by this type's `IntoDatum`
                        // implementation for the current PostgreSQL call.
                        unsafe { fcinfo.return_raw_datum(datum) }
                    }
                    None => fcinfo.return_null(),
                }
            }
        }
    };
}

pub(crate) use impl_pinned_datum;
