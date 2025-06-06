#!/bin/bash

# Starts the echo server
# Enabled bash job control!
set -emo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "${DIR}/k8s-common"

# Do benchmark pre-work
#f_benchmark_pre

# Starts the echo server with a restricted CPU affinity
echo "** Starting with base cpu core ${CGROUP_CPUSETS[1]}"
taskset -c "${CGROUP_CPUSETS[1]}" "${DIR}/../aeron/cluster-node" "${@}" &

# Wait for Java process to be up
f_wait_for_process 'io.aeron.benchmarks.aeron.ClusterNode'

f_wait_for_thread 'clustered-servi' 3

# Sets the affinities main echo thread
f_pin_thread "clustered-servi" "${CGROUP_CPUSETS[2]}"

# Wait for all background tasks
fg

# Do our post-benchmark work
f_benchmark_post
