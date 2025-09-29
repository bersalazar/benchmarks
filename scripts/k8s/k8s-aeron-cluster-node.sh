#!/usr/bin/env bash

# Starts the cluster node
# Enabled bash job control!
set -emo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "${DIR}/k8s-common"

# Do benchmark pre-work
f_benchmark_pre

# Starts the cluster node with a restricted CPU affinity
echo "** Starting with base cpu core ${CGROUP_CPUSETS[0]}"
taskset -c "${CGROUP_CPUSETS[0]}" "${DIR}/../aeron/cluster-node" "${@}" &

# Wait for Java process to be up
f_wait_for_process 'io.aeron.benchmarks.aeron.ClusterNode'

# Waits for thread to start (in seconds) and sets its affinity
f_wait_for_thread 'clustered-servi' 3 #TODO: consider f_wait_for_threads and pass an array of thread names

# Sets the affinities for high performance threads
f_pin_thread "clustered-servi" "${CGROUP_CPUSETS[0]}"
f_pin_thread "archive-recorde" "${CGROUP_CPUSETS[1]}"
f_pin_thread "archive-replaye" "${CGROUP_CPUSETS[2]}"
f_pin_thread "archive-conduct" "${CGROUP_CPUSETS[3]}"
f_pin_thread "consensus-modul" "${CGROUP_CPUSETS[4]}"
f_pin_thread "aeron-client-co" "${CGROUP_CPUSETS[5]}"

# Wait for all background tasks
fg

# Do our post-benchmark work
f_benchmark_post
