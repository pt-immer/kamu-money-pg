#!/usr/bin/env bash
# Remove only the private directory created by 09-wire.setup.sh.
set -euo pipefail

: "${KMONEY_SUITE_DIR:?run-suite.sh must supply KMONEY_SUITE_DIR}"
case "$KMONEY_SUITE_DIR" in
    /tmp/kmoney-suite.*) ;;
    *)
        echo "09-wire.cleanup: refusing unexpected path: $KMONEY_SUITE_DIR" >&2
        exit 2
        ;;
esac

rm -rf -- "$KMONEY_SUITE_DIR"
echo "09-wire.cleanup: removed temporary fixtures"
