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
      K8S_NAMESPACE="${2}"
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
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
TEST_TO_RUN="${TEST_TO_RUN:-aeron-cluster-c}"
INTERFACE="${INTERFACE:-eth0}"

TIMESTAMP="$(date +"%Y-%m-%d-%H-%M-%S")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "${SCRIPT_DIR}"

function f_cleanup_k8s() {
  f_log "Deleting old benchmark setup"
  if [[ "${1}" == *cluster* ]]; then
    kubectl --namespace "${K8S_NAMESPACE}" delete --wait=true  --kustomize "k8s/${CLUSTER_DEPLOY}" || true
    kubectl --namespace "${K8S_NAMESPACE}" delete --wait=true  --kustomize "k8s/${CLIENT_DEPLOY}" || true
    kubectl --namespace "${K8S_NAMESPACE}" delete --wait=true endpointslices.discovery.k8s.io/aeron-cluster-client-md || true
    kubectl --namespace "${K8S_NAMESPACE}" delete --wait=true endpointslices.discovery.k8s.io/aeron-cluster-md || true
    kubectl --namespace "${K8S_NAMESPACE}" wait --for=delete endpointslices.discovery.k8s.io/aeron-cluster-md --timeout=60s || true
    kubectl --namespace "${K8S_NAMESPACE}" wait --for=delete endpointslices.discovery.k8s.io/aeron-cluster-client-md --timeout=60s || true
    kubectl --namespace "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=delete pod/aeron-cluster-0 || true
    kubectl --namespace "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=delete pod/aeron-cluster-1 || true
    kubectl --namespace "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=delete pod/aeron-cluster-2 || true
    kubectl --namespace "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=delete pod/aeron-cluster-client || true
  else
    kubectl --namespace "${K8S_NAMESPACE}" delete --wait=true  --kustomize "k8s/${TEST_TO_RUN}" || true
    kubectl --namespace "${K8S_NAMESPACE}" wait --timeout=60s --for=delete endpointslices.discovery.k8s.io/aeron-benchmark-md1 || true
    kubectl --namespace "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=delete pod/aeron-benchmark-0 || true
    kubectl --namespace "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=delete pod/aeron-benchmark-1 || true
  fi
}

f_cleanup_k8s "${TEST_TO_RUN}"

f_log "Creating namespace: ${K8S_NAMESPACE}"
kubectl create namespace "${K8S_NAMESPACE}" || true

if [[ "${TEST_TO_RUN}" == *cluster* ]]; then
  f_log "Generating new benchmark setup for: ${TEST_TO_RUN}"

  f_log "Deploying cluster: ${CLUSTER_DEPLOY}"
  kubectl --namespace "${K8S_NAMESPACE}" apply --wait=true --kustomize "k8s/${CLUSTER_DEPLOY}"
  kubectl -n "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=ContainersReady=true pod/aeron-cluster-0
  kubectl -n "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=ContainersReady=true pod/aeron-cluster-1
  kubectl -n "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=ContainersReady=true pod/aeron-cluster-2

  # Get the media driver IPs from the cluster pods
  if [[ "${TEST_TO_RUN}" =~ .*-dpdk$ ]]; then
    AERON_0_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec -it aeron-cluster-0 -c aeronmd-dpdk -- bash -c 'echo ${PCIDEVICE_INTEL_COM_AWS_DPDK_INFO}' | jq -r '.. | ."IPV4_ADDRESS"? | select(. != null)')"
    AERON_1_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec -it aeron-cluster-1 -c aeronmd-dpdk -- bash -c 'echo ${PCIDEVICE_INTEL_COM_AWS_DPDK_INFO}' | jq -r '.. | ."IPV4_ADDRESS"? | select(. != null)')"
    AERON_2_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec -it aeron-cluster-2 -c aeronmd-dpdk -- bash -c 'echo ${PCIDEVICE_INTEL_COM_AWS_DPDK_INFO}' | jq -r '.. | ."IPV4_ADDRESS"? | select(. != null)')"
  elif [[ "${TEST_TO_RUN}" =~ .*-java$ ]]; then
    AERON_0_MD_IP="$(kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-0  -c aeronmd-java -- bash -c "ip -4 -json addr show ${INTERFACE} | jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
    AERON_1_MD_IP="$(kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-1  -c aeronmd-java -- bash -c "ip -4 -json addr show ${INTERFACE} | jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
    AERON_2_MD_IP="$(kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-2  -c aeronmd-java -- bash -c "ip -4 -json addr show ${INTERFACE} | jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
  elif [[ "${TEST_TO_RUN}" =~ .*-c$ ]]; then
    AERON_0_MD_IP="$(kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-0  -c aeronmd-c -- bash -c "ip -4 -json addr show ${INTERFACE} | jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
    AERON_1_MD_IP="$(kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-1  -c aeronmd-c -- bash -c "ip -4 -json addr show ${INTERFACE} | jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
    AERON_2_MD_IP="$(kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-2  -c aeronmd-c -- bash -c "ip -4 -json addr show ${INTERFACE} | jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
  else
    f_log "Media driver config not found"
    exit 1
  fi

  f_log "Found Media driver IPs:"
  echo "aeron-cluster-0: ${AERON_0_MD_IP}"
  echo "aeron-cluster-1: ${AERON_1_MD_IP}"
  echo "aeron-cluster-2: ${AERON_2_MD_IP}"

  # Generate endpoint slice with IPs
  # Because we can use interfaces that have no obvious IPs, we need to have a way to generate DNS records for the test.
  f_log "Generating EndpointSlice with DNS for media driver IPs"
  ENDPOINT_SLICE=$(cat <<EOF
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: aeron-cluster-md
  labels:
    kubernetes.io/service-name: aeron-cluster
    endpointslice.kubernetes.io/managed-by: caf-benchmark
addressType: IPv4
endpoints:
  - addresses:
      - ${AERON_0_MD_IP}
    hostname: aeron-cluster-0
  - addresses:
      - ${AERON_1_MD_IP}
    hostname: aeron-cluster-1
  - addresses:
      - ${AERON_2_MD_IP}
    hostname: aeron-cluster-2
EOF
)
  # Inject endpoint slice
  echo "${ENDPOINT_SLICE}" | kubectl -n "${K8S_NAMESPACE}" apply -f -
  f_log "Deploying client: ${CLIENT_DEPLOY}"
  kubectl --namespace "${K8S_NAMESPACE}" apply --wait=true --kustomize "k8s/${CLIENT_DEPLOY}"
  kubectl -n "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=ContainersReady=true pod/aeron-cluster-client

  # Get the media driver IPs from the client pod
  if [[ "${TEST_TO_RUN}" =~ .*-dpdk$ ]]; then
    AERON_CLIENT_MD_IP="$(kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-client  -c aeronmd-dpdk -- bash -c "ip -4 -json addr show ${INTERFACE} |   jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
  elif [[ "${TEST_TO_RUN}" =~ .*-java$ ]]; then
    AERON_CLIENT_MD_IP="$(kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-client  -c aeronmd-java -- bash -c "ip -4 -json addr show ${INTERFACE} |   jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
  elif [[ "${TEST_TO_RUN}" =~ .*-c$ ]]; then
    AERON_CLIENT_MD_IP="$(kubectl --namespace "${K8S_NAMESPACE}" exec aeron-cluster-client  -c aeronmd-c -- bash -c "ip -4 -json addr show ${INTERFACE} | jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
  else
    f_log "Media driver config not found"
    exit 1
  fi

  f_log "Found Media driver IPs:"
  echo "aeron-cluster-client: ${AERON_CLIENT_MD_IP}"

  f_log "Generating EndpointSlice with DNS for aeron cluster client media driver IP"
  ENDPOINT_SLICE=$(cat <<EOF
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: aeron-cluster-client-md
  labels:
    kubernetes.io/service-name: aeron-cluster-client
    endpointslice.kubernetes.io/managed-by: caf-benchmark
addressType: IPv4
endpoints:
  - addresses:
      - ${AERON_CLIENT_MD_IP}
    hostname: aeron-cluster-client
EOF
)
  echo "${ENDPOINT_SLICE}" | kubectl -n "${K8S_NAMESPACE}" apply -f -

  # When the benchmark finishes, the benchmark containers stop, generating a NotReady condition
  f_log "Waiting for benchmarks to finish"
  kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready=false --timeout=360s pod/aeron-cluster-0
  kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready=false --timeout=360s pod/aeron-cluster-1
  kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready=false --timeout=360s pod/aeron-cluster-2
  kubectl -n "${K8S_NAMESPACE}" wait --for=condition=Ready=false --timeout=360s pod/aeron-cluster-client

  f_log "Benchmarks finished, showing logs"
  kubectl -n "${K8S_NAMESPACE}" logs -c aeron-cluster-client aeron-cluster-client

  # f_log "Collecting data"
  # mkdir -p "results/${TIMESTAMP}"
  #
  # # Dump all the logs to the results-dir
  # kubectl -n "${K8S_NAMESPACE}" logs --all-containers=true  aeron-benchmark-0 > results/${TIMESTAMP}/logs-0.txt
  # kubectl -n "${K8S_NAMESPACE}" logs --all-containers=true  aeron-benchmark-1 > results/${TIMESTAMP}/logs-1.txt
  #
  # # Copy the tarball of results over
  # kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-benchmark-0:/dev/shm/results.tar.gz "results/${TIMESTAMP}/results-0.tar.gz"
  # kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-benchmark-1:/dev/shm/results.tar.gz "results/${TIMESTAMP}/results-1.tar.gz"

else
  kubectl -n "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=ContainersReady=true pod/aeron-benchmark-0
  kubectl -n "${K8S_NAMESPACE}" wait --timeout=90s --for=condition=ContainersReady=true pod/aeron-benchmark-1
  # DPDK Media Driver
  if [[ "${TEST_TO_RUN}" =~ .*-dpdk$ ]]; then
    AERON_0_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec -it aeron-benchmark-0 -c aeronmd-dpdk -- bash -c 'echo ${PCIDEVICE_INTEL_COM_AWS_DPDK_INFO}' | jq -r '.. | ."IPV4_ADDRESS"? | select(. != null)')"
    AERON_CLIENT_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec -it aeron-benchmark-1 -c aeronmd-dpdk -- bash -c 'echo ${PCIDEVICE_INTEL_COM_AWS_DPDK_INFO}' | jq -r '.. | ."IPV4_ADDRESS"? | select(. != null)')"
  # Java Media Driver
  elif [[ "${TEST_TO_RUN}" =~ .*-java$ ]]; then
    AERON_0_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec aeron-benchmark-0  -c aeronmd-java -- bash -c "ip -4 -json addr show ${INTERFACE} |   jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
    AERON_CLIENT_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec aeron-benchmark-1  -c aeronmd-java -- bash -c "ip -4 -json addr show ${INTERFACE} |   jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
  elif [[ "${TEST_TO_RUN}" =~ .*-c$ ]]; then
    AERON_0_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec aeron-benchmark-0  -c aeronmd-c -- bash -c "ip -4 -json addr show ${INTERFACE} |   jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
    AERON_CLIENT_MD_IP="$(kubectl -n "${K8S_NAMESPACE}" exec aeron-benchmark-1  -c aeronmd-c -- bash -c "ip -4 -json addr show ${INTERFACE} |   jq -r '.[] | .addr_info[] | select(.family == \"inet\") | .local'")"
  else
    f_log "Media driver config not found"
    exit 1
  fi

  f_log "Found Media driver IPs:"
  echo "aeron-benchmark-0: ${AERON_0_MD_IP}"
  echo "aeron-benchmark-1: ${AERON_CLIENT_MD_IP}"

  # Generate endpoint slice with IPs
  # Because we can use interfaces that have no obvious IPs, we need to have a way to generate DNS records for the test.
  f_log "Generating endpointslice with DNS for media driver IPs"
  ENDPOINT_SLICE=$(cat <<EOF
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: aeron-benchmark-md1
  labels:
    kubernetes.io/service-name: aeron-benchmark-md
addressType: IPv4
ports:
  # Port/protocol is irrelevant as this is a headless service
  - port: 10000
    name: ''
    protocol: UDP
endpoints:
  - addresses:
      - ${AB0_MD_IP}
    hostname: aeron-benchmark-0
  - addresses:
      - ${AB1_MD_IP}
    hostname: aeron-benchmark-1
EOF
)
  # Inject endpoint slice
  echo "${ENDPOINT_SLICE}" | kubectl -n "${K8S_NAMESPACE}" apply -f -

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
  kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-benchmark-0:/dev/shm/results.tar.gz "results/${TIMESTAMP}/results-0.tar.gz"
  kubectl -n "${K8S_NAMESPACE}" cp -c results aeron-benchmark-1:/dev/shm/results.tar.gz "results/${TIMESTAMP}/results-1.tar.gz"
fi

# Extract the useful files
for tarfile in results-1.tar.gz
do
    tar -C "results/${TIMESTAMP}" --strip-components=1 --wildcards -xf "results/${TIMESTAMP}/${tarfile}" '*.png'
    tar -C "results/${TIMESTAMP}" --strip-components=1 --wildcards -xf "results/${TIMESTAMP}/${tarfile}" '*.hgrm'
done

f_log "Results collected in: ${SCRIPT_DIR}/results/${TIMESTAMP}"

f_cleanup_k8s
