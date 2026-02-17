#!/bin/bash

set -eo pipefail

function f_log() {
  echo "******************************************************************"
  echo "** $*"
}

function f_show_help() {
  f_log "Supported arguments are:"
  echo "${0} (-n|--namespace '<namespace>' ) (-t|--test 'aeron-echo-dpdk|aeron-echo-java|aeron-echo-c|aeron-cluster-c|aeron-cluster-java|aeron-cluster-dpdk' ) (-i|--interface <ignored for DPDK> 'eth0')"
}

declare -r valid_tests=(
  "aeron-cluster-c"
  "aeron-cluster-dpdk"
  "aeron-cluster-java"
  "aeron-echo-c"
  "aeron-echo-dpdk"
  "aeron-echo-java"
)

while [[ $# -gt 0 ]]
do
  option="${1}"
  case ${option} in
    -n|--namespace)
      K8S_NAMESPACE="${2:-aeron-benchmark}"
      shift
      shift
      ;;
    -t|--test)
      TEST_TO_RUN="${2}"
      if ! [[ "${valid_tests[*]}" =~ ${TEST_TO_RUN} ]]; then
        f_log "ERROR: unsupported test '${TEST_TO_RUN}'. Valid values are: 'aeron-echo-dpdk', 'aeron-echo-java', 'aeron-echo-c', 'aeron-cluster-c', 'aeron-cluster-java', 'aeron-cluster-dpdk'"
        exit 1
      fi

      if [[ "${TEST_TO_RUN}" == *cluster* ]]; then
        case "${TEST_TO_RUN}" in
          aeron-cluster-c)
            CLUSTER_DEPLOY="aeron-cluster/cluster-c"
            CLIENT_DEPLOY="aeron-cluster/client-c"
            ;;
          aeron-cluster-java)
            CLUSTER_DEPLOY="aeron-cluster/cluster-java"
            CLIENT_DEPLOY="aeron-cluster/client-java"
            ;;
          aeron-cluster-dpdk)
            CLUSTER_DEPLOY="aeron-cluster/cluster-dpdk"
            CLIENT_DEPLOY="aeron-cluster/client-dpdk"
            ;;
        esac
      fi
      shift
      shift
      ;;
    -i|--interface)
      INTERFACE="${2}"
      shift
      shift
      ;;
    -h|--help)
      f_show_help
      exit 1
      ;;
    *)
      echo "ERROR: unknown argument: ${option}"
      f_show_help
      exit 1
      ;;
  esac
done

# Standard vars
K8S_NAMESPACE="${K8S_NAMESPACE:-aeron-benchmark}"
TEST_TO_RUN="${TEST_TO_RUN:-aeron-cluster-java}"
INTERFACE="${INTERFACE:-eth0}"

TIMESTAMP="$(date +"%Y-%m-%d-%H-%M-%S")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "${SCRIPT_DIR}"

f_log "Deleting old benchmark setup"
kubectl delete namespace "${K8S_NAMESPACE}" || true

f_log "Creating namespace: ${K8S_NAMESPACE}"
kubectl create namespace "${K8S_NAMESPACE}" || true

declare -r RESULTS_FILENAME="results-cluster-client"
if [[ "${TEST_TO_RUN}" == *cluster* ]]; then

  f_log "Generating aeron cluster benchmark setup for: ${TEST_TO_RUN}"

  f_log "Deploying cluster: ${CLUSTER_DEPLOY}"
  kubectl --namespace "${K8S_NAMESPACE}" apply --wait=true --kustomize "k8s/${CLUSTER_DEPLOY}"
  kubectl --namespace "${K8S_NAMESPACE}" rollout status --timeout=2m statefulset/aeron-cluster

  f_log "Deploying aeron cluster client: ${CLIENT_DEPLOY}"
  kubectl --namespace "${K8S_NAMESPACE}" apply --wait=true --kustomize "k8s/${CLIENT_DEPLOY}"
  kubectl -n "${K8S_NAMESPACE}" wait --timeout=120s --for=condition=Ready=true pod/aeron-cluster-client

  # When the benchmark finishes, the benchmark containers stop, generating a NotReady condition
  f_log "Waiting for benchmarks to finish"
  kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready=false --timeout=360s pod/aeron-cluster-client

  f_log "Benchmarks finished, showing client logs"
  kubectl -n "${K8S_NAMESPACE}" logs -c aeron-cluster-client aeron-cluster-client

  f_log "Collecting environment info, aeron-stat and logs"
  kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-0 -c aeron-cluster-node -- bash "/opt/aeron-benchmarks/scripts/collect-environment-info" "/dev/shm/results"
  kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-1 -c aeron-cluster-node -- bash "/opt/aeron-benchmarks/scripts/collect-environment-info" "/dev/shm/results"
  kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-2 -c aeron-cluster-node -- bash "/opt/aeron-benchmarks/scripts/collect-environment-info" "/dev/shm/results"

  # Send SIGINT to cluster nodes so they dump aeron-stat and logs
  kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-0 -c aeron-cluster-node -- pkill -SIGINT java
  kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-1 -c aeron-cluster-node -- pkill -SIGINT java
  kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-2 -c aeron-cluster-node -- pkill -SIGINT java

  f_log "Collecting data"
  mkdir -p "results/${TIMESTAMP}" "results/${TIMESTAMP}/aeron-cluster-0" "results/${TIMESTAMP}/aeron-cluster-1" "results/${TIMESTAMP}/aeron-cluster-2"

  # Dump all the logs to the results-dir
  kubectl -n "${K8S_NAMESPACE}" logs --all-containers=true  aeron-cluster-client > "results/${TIMESTAMP}/logs-cluster-client.txt"

  # Copy the results over
  kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-cluster-client:/dev/shm/results.tar.gz "results/${TIMESTAMP}/${RESULTS_FILENAME}.tar.gz"
  kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-cluster-0:/dev/shm/results "results/${TIMESTAMP}/aeron-cluster-0"
  kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-cluster-1:/dev/shm/results "results/${TIMESTAMP}/aeron-cluster-1"
  kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-cluster-2:/dev/shm/results "results/${TIMESTAMP}/aeron-cluster-2"

else
  f_log "Generating new benchmark setup for: ${TEST_TO_RUN}"
  kubectl --namespace "${K8S_NAMESPACE}" apply --wait=true --kustomize "k8s/${TEST_TO_RUN}"
  kubectl -n "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=ContainersReady=true pod/aeron-benchmark-0
  kubectl -n "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=ContainersReady=true pod/aeron-benchmark-1

  # When the benchmark finishes, the benchmark containers stop, generating a NotReady condition
  f_log "Waiting for benchmarks to finish"
  kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready=false --timeout=360s pod/aeron-benchmark-0
  kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready=false --timeout=360s pod/aeron-benchmark-1

  f_log "Benchmarks finished, showing logs"

  # Show the raw output
  kubectl -n "${K8S_NAMESPACE}" logs -c benchmark aeron-benchmark-1

  f_log "Collecting data"
  mkdir -p "results/${TIMESTAMP}"

  # Dump all the logs to the results-dir
  kubectl -n "${K8S_NAMESPACE}" logs --all-containers=true  aeron-benchmark-0 > results/${TIMESTAMP}/logs-0.txt
  kubectl -n "${K8S_NAMESPACE}" logs --all-containers=true  aeron-benchmark-1 > results/${TIMESTAMP}/logs-1.txt

  # Copy the tarball of results over
  kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-benchmark-1:/dev/shm/results.tar.gz "results/${TIMESTAMP}/${RESULTS_FILENAME}.tar.gz"
fi

# Extract the useful files
tar -C "results/${TIMESTAMP}" --strip-components=1 --wildcards -xf "results/${TIMESTAMP}/${RESULTS_FILENAME}.tar.gz" '*.png' || echo "No PNG files found in results"
tar -C "results/${TIMESTAMP}" --strip-components=1 --wildcards -xf "results/${TIMESTAMP}/${RESULTS_FILENAME}.tar.gz" '*.hgrm' "" || echo "No HGRM files found in results"
tar -C "results/${TIMESTAMP}" --strip-components=1 --wildcards -xf "results/${TIMESTAMP}/${RESULTS_FILENAME}.tar.gz" '*.hgrm.FAIL' "" || true

f_log "Results collected in: ${SCRIPT_DIR}/results/${TIMESTAMP}"

f_log "Cleaning up the benchmark setup"
#kubectl delete namespace "${K8S_NAMESPACE}" || true
