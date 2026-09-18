#!/usr/bin/env bash
# Write the crafted BINARY COPY payloads 09-wire.sql feeds to `kmoney_recv`.
#
# Runs ON THE SERVER (the runner pipes it into `--server-exec`, e.g. `docker exec -i <node>
# bash`), because COPY ... FROM reads a path in the server's filesystem, not the client's.
#
# WHY A SHELL SCRIPT AND NOT SQL. `kmoney_recv` takes `internal`, which has no SQL literal, so
# the only in-database route to it is COPY (FORMAT BINARY) -- which needs a file whose bytes are
# deliberately wrong. SQL has no primitive that writes arbitrary bytes to a file. The Rust tests
# do it with std::fs from inside the backend; from out here it is printf.
#
# DEPENDENCIES: printf and chmod. Deliberately not python, xxd, dd or perl -- this has to run
# inside a stock YugabyteDB image and inside the stock-PG15 reference, and each extra tool is
# another thing that can be absent on one of them.
#
# THE LAYOUT, which every offset below depends on. A one-row one-field BINARY COPY file is:
#
#     11  signature   PGCOPY\n\377\r\n\0
#      4  flags       0
#      4  header ext  0
#      2  field count 1                     (int16, network order)
#      4  field len   18                    (int32, network order)
#     18  payload     16 LE units, 2 LE ISO 4217 numeric code
#      2  trailer     -1                    (int16 0xffff)
#     --
#     45  bytes
#
# so the payload occupies [25..43) and the trailer [43..45). Those are the same offsets the Rust
# tests use, and 09-wire.sql re-asserts the good payload against a live `kmoney_send` so this
# file cannot drift away from what the type actually writes.
set -euo pipefail

D=$(mktemp -d /tmp/kmoney-suite.XXXXXX)
chmod 0700 "$D"
# Machine-readable handoff to run-suite.sh. Print this before later work so the runner can clean
# the directory even if a fixture assertion fails.
printf 'KMONEY_SUITE_DIR=%s\n' "$D"

# 11-byte signature, then flags and header-extension, both int32 zero.
HDR='\x50\x47\x43\x4f\x50\x59\x0a\xff\x0d\x0a\x00\x00\x00\x00\x00\x00\x00\x00\x00'
FIELDS='\x00\x01'          # one field in this tuple
LEN18='\x00\x00\x00\x12'   # field length 18 -- the mixed payload
LEN16='\x00\x00\x00\x10'   # field length 16 -- the pinned payload
LEN10='\x00\x00\x00\x0a'   # field length 10 -- the truncated probe
LEN26='\x00\x00\x00\x1a'   # field length 26 -- the trailing-bytes probe
TRAILER='\xff\xff'

# USD 1.00 = 10^18 canonical units, little-endian; ISO 4217 numeric 840 (USD), little-endian.
# 09-wire.sql asserts `encode(kmoney_send('USD 1.00'::kmoney),'hex')` equals exactly these bytes.
UNITS_ONE='\x00\x00\x64\xa7\xb3\xb6\xe0\x0d\x00\x00\x00\x00\x00\x00\x00\x00'
UNITS_ONE_10='\x00\x00\x64\xa7\xb3\xb6\xe0\x0d\x00\x00'   # the first 10 of those 16
# 10^36 -- one past the domain top (|units| <= 10^36 - 1), little-endian.
UNITS_OVER='\x00\x00\x00\x00\x10\x9f\x4b\xb3\x15\x07\xc9\x7b\xce\x97\xc0\x00'
USD='\x48\x03'      # 840, little-endian
NOCUR='\x00\x00'    # 0 is not an assigned ISO 4217 numeric code
PAD8='\x00\x00\x00\x00\x00\x00\x00\x00'

# The variables ARE the format string, which is what makes printf interpret \xNN. None of them
# contain a `%`, so there is no format-injection surface here.
# shellcheck disable=SC2059
write() { printf "$2" > "$D/$1"; chmod 0600 "$D/$1"; }

# Valid framing, units one past the domain top, currency left valid -> the DOMAIN check fires.
write kmoney_suite_bad_domain.bin "$HDR$FIELDS$LEN18$UNITS_OVER$USD$TRAILER"
# The PINNED variant: 16 currency-less bytes, one past the domain top -> the shared
# pinned recv's domain check fires, and its message names the per-type SQL function.
write kmoney_suite_bad_pin_domain.bin "$HDR$FIELDS$LEN16$UNITS_OVER$TRAILER"
# Valid framing, valid units, currency code 0 -> the CURRENCY check fires.
write kmoney_suite_bad_nocur.bin  "$HDR$FIELDS$LEN18$UNITS_ONE$NOCUR$TRAILER"
# Field length AND payload both cut to 10, so the file stays self-consistent and it is recv --
# not COPY's framing check -- that refuses.
write kmoney_suite_bad_short.bin  "$HDR$FIELDS$LEN10$UNITS_ONE_10$TRAILER"
# 26 bytes offered where recv wants 18: pq_getmsgend must reject the 8 that are left over.
write kmoney_suite_bad_long.bin   "$HDR$FIELDS$LEN26$UNITS_ONE$USD$PAD8$TRAILER"

# Fail closed on the one thing printf can get wrong: a mis-typed escape silently shortens a file.
# Without this, a 44-byte "good" payload would be refused for the WRONG reason and the case would
# still pass, because the expected output is an error either way.
for f in bad_domain:45 bad_pin_domain:43 bad_nocur:45 bad_short:37 bad_long:53; do
    name="${f%%:*}"; want="${f##*:}"
    got=$(wc -c < "$D/kmoney_suite_$name.bin")
    [ "$got" -eq "$want" ] || {
        echo "09-wire.setup: $name.bin is $got bytes, expected $want -- a printf escape is wrong" >&2
        exit 1
    }
done
echo "09-wire.setup: wrote 5 crafted payloads"
