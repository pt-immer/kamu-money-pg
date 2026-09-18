#!/usr/bin/env bash
# Print the ONE path under a directory whose name matches a pattern, or refuse.
#
#   exactly-one.sh <root> <name-pattern>
#
# The YugabyteDB image's copy-out step assembles a triplet -- library, control file and install
# script -- out of a build tree, and the three must come from the SAME build. `find ... | head -1`
# was the earlier shape, once per file. `find` has no defined order, so that was "whichever path
# the filesystem handed back first"; had a tree ever carried two majors' artifacts, the three
# searches could each have picked from a different one and assembled a triplet that installs
# cleanly while the library and the SQL script disagree.
#
# Counting the matches turns that silent choice into a failure. It lives in a file rather than
# inline in the Dockerfile because an assertion that only ever runs inside a Docker build cannot
# be falsified without inventing a build argument to break it. Here
# `hygiene/tests/exactly_one.rs` exercises every branch, on the host, in `test-hygiene`.
set -euo pipefail

[ "$#" -eq 2 ] || {
    echo "exactly-one: usage: exactly-one.sh <root> <name-pattern>" >&2
    exit 2
}

root="$1"
pattern="$2"

[ -d "$root" ] || {
    echo "exactly-one: no directory at '$root'" >&2
    exit 2
}

# read -r rather than `mapfile`, so the count is right for a path containing a backslash.
matches=()
while IFS= read -r match; do
    matches+=("$match")
done < <(find "$root" -name "$pattern")

if [ "${#matches[@]}" -ne 1 ]; then
    printf 'exactly-one: expected exactly one %s under %s/, found %d\n' \
        "$pattern" "$root" "${#matches[@]}" >&2
    if [ "${#matches[@]}" -gt 0 ]; then
        printf '  %s\n' "${matches[@]}" >&2
    fi
    exit 1
fi

printf '%s\n' "${matches[0]}"
