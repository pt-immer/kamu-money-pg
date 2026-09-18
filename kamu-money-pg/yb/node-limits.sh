#!/usr/bin/env bash
# YugabyteDB node resource limits. Sourced, never executed.
#
#   source kamu-money-pg/yb/node-limits.sh
#   docker run --memory "$YB_NODE_MEM" --memory-swap "$YB_NODE_MEM" ... \
#       bin/yugabyted start --tserver_flags="memory_limit_hard_bytes=$YB_TSERVER_MEM_BYTES" \
#                           --master_flags="memory_limit_hard_bytes=$YB_MASTER_MEM_BYTES"
#
# A container sees host memory, so yugabyted can size each tserver beyond its container budget.
# Explicit Docker and YugabyteDB limits keep a multi-node suite within a 16 GB runner.
#
# These are correctness-suite defaults, not benchmark settings. Three primaries plus two replicas
# use 10 GB; callers may override the variables for measurement.
#
# Set `--memory-swap` equal to `--memory` so paging cannot distort timing.
#
# Every harness sources this file.

# Docker's hard ceiling per node container.
YB_NODE_MEM="${YB_NODE_MEM:-2g}"
# What yugabyted is TOLD it may use, kept under the container ceiling so the process refuses
# cleanly inside its own limit rather than being killed from outside it.
YB_TSERVER_MEM_BYTES="${YB_TSERVER_MEM_BYTES:-1073741824}"   # 1 GiB
YB_MASTER_MEM_BYTES="${YB_MASTER_MEM_BYTES:-536870912}"      # 512 MiB
