#!/usr/bin/env bash
# Serialize writers to the default workspace scratch root.
#
#   source ./kamu-money-pg/yb/workspace-lock.sh
#   workspace_lock "release-check"
#
# A unique explicit `KMONEY_RUN_ROOT` gives one run a private artifact tree, so no
# lock is needed. With the variable unset, manual and legacy calls share:
#
#   <root>/{kmoney.so,kmoney.control,kmoney--*.sql}   the extracted triplet
#   <root>/out-yb.txt                                 the YB battery output
#   <root>/ref/out-pg15.txt                           the stock-PG15 reference
#   <root>/regress-yb, regress-cluster-n*, suite-n*.log, concurrent, release-suites
#
# Concurrent writers there can combine artifacts, hashes, references, and logs
# from different runs. `flock -n` refuses the second writer immediately.
#
# Source this file: the caller must retain the open lock descriptor for its
# lifetime. Descendants may reuse the lock only when the inherited descriptor
# resolves to this exact lock file.

# Where the lock lives: resolved from THIS file, not from the caller's cwd, so a script that has
# already `cd`'d somewhere still finds the one lock.
# IS THE INHERITED LOCK REAL? Answers from the kernel, not from an environment variable.
#
# `KMONEY_WORKSPACE_LOCK_FD` names a descriptor number. This checks that the number is open in
# THIS process and that it refers to the very lock file we were about to take -- which is exactly
# the property "a descendant of the holder" means, and the only one that cannot be produced by
# typing a variable on a command line. `/proc/$$/fd/N` is a symlink to the open file's path, so
# the comparison is against the file, not against the caller's word for it.
_workspace_lock_inherited() {
    local want="$1" fd="${KMONEY_WORKSPACE_LOCK_FD:-}" got
    case "$fd" in ''|*[!0-9]*) return 1 ;; esac
    [ -e "/proc/$$/fd/$fd" ] || return 1
    got="$(readlink -f "/proc/$$/fd/$fd" 2>/dev/null)" || return 1
    want="$(readlink -f "$want" 2>/dev/null)" || return 1
    [ -n "$got" ] && [ -n "$want" ] && [ "$got" = "$want" ]
}

workspace_lock() {
    local what="${1:-a workspace suite}"

    # A caller-provided run root owns no default-root paths. `KMONEY_LOCK_DIR`
    # is the self-test override and deliberately keeps locking enabled.
    if [ -n "${KMONEY_RUN_ROOT:-}" ] && [ -z "${KMONEY_LOCK_DIR:-}" ]; then
        return 0
    fi

    # `KMONEY_LOCK_DIR` exists only for fixture-backed self-tests. Resolve it before checking
    # re-entrancy because the inherited descriptor must point to this exact path.
    local dir
    dir="${KMONEY_LOCK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/out}"
    mkdir -p "$dir"
    local lock="$dir/.workspace.lock" holder="$dir/.workspace.holder"

    # Descendants inherit the open descriptor and may re-enter. An environment flag alone never
    # proves ownership.
    #
    # The descriptor is the thing that actually holds the lock, so the descriptor is what gets
    # checked. A forged variable now names a number that is either not open or is open on some
    # other file, and both refuse.
    if [ -n "${KMONEY_WORKSPACE_LOCK_FD:-}" ]; then
        if _workspace_lock_inherited "$lock"; then
            return 0
        fi
        {
            printf 'workspace-lock: REFUSING to start %s -- KMONEY_WORKSPACE_LOCK_FD is set to\n' "$what"
            printf 'workspace-lock: %s, but that descriptor is not an open handle on\n' "${KMONEY_WORKSPACE_LOCK_FD}"
            printf 'workspace-lock: %s in this process.\n\n' "$lock"
            cat <<'EOF'
That variable means "an ancestor already holds the workspace lock and passed me its descriptor".
Only the descriptor proves it, and this process does not have it -- so either the variable was set
by hand, or it was inherited from a run that has since exited, or the lock directory moved
(KMONEY_LOCK_DIR). Proceeding would let two writers into the fixed scratch paths with nothing
raising, which is the failure this lock exists to make impossible.

Unset KMONEY_WORKSPACE_LOCK_FD and run this command directly.
EOF
        } >&2
        return 1
    fi

    # APPEND MODE, so that opening the lock file does not truncate it. With `>` a refused caller
    # would destroy the holder record in the act of trying to read it.
    exec {KMONEY_LOCK_FD}>>"$lock"

    if flock -n "$KMONEY_LOCK_FD"; then
        printf 'what     %s\npid      %s\nstarted  %s\n' \
            "$what" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$holder"
        # THE DESCRIPTOR NUMBER, exported, so nested `just` recipes and runner scripts can VERIFY
        # the inheritance rather than be told about it. bash does not set close-on-exec on a
        # `{var}>` descriptor, so the number is still open on the same file in every descendant --
        # which is what `_workspace_lock_inherited` checks and what makes the claim falsifiable.
        #
        # Not unset on the way out: the lock is released when this shell exits and closes the
        # descriptor, which is the only release that is correct under a kill.
        export KMONEY_WORKSPACE_LOCK_FD="$KMONEY_LOCK_FD"
        return 0
    fi

    {
        printf 'workspace-lock: REFUSING to start %s -- another run owns this checkout.\n\n' "$what"
        if [ -s "$holder" ]; then
            sed 's/^/  /' "$holder"
        else
            printf '  (no holder record; the lock is held but its owner did not write one)\n'
        fi
        cat <<'EOF'

Both runs are using the DEFAULT scratch root, kamu-money-pg/yb/out/ -- the extracted extension
triplet, the A/B battery output and its PG15 reference, the regress and cluster and concurrency
work directories, and the parallel suite logs. Two writers there do not fail loudly; they produce
one run overwriting output another is mid-way through reading.

Give this run its own tree instead of waiting:

    KMONEY_RUN_ROOT=kamu-money-pg/yb/out/runs/$(date -u +%Y%m%dT%H%M%SZ)-$$ <your command>

Every path listed above resolves from that variable, so a run that sets it shares nothing and is
not refused. Waiting for the other run to finish, or using a separate checkout, both still work.

If the pid above is gone and the lock is STILL held, look for its orphaned children: the lock is
an open file descriptor and every descendant inherits it, so a suite that outlived the script
which started it is still holding -- and is still writing these files, which is why it counts.
  ps -o pid,ppid,lstart,cmd -e | grep -E 'yugabyte|docker|cargo|run-yb'
EOF
    } >&2
    return 1
}
