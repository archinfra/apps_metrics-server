#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="metrics-server"
INSTALLER_VERSION="0.1.2"
WORKDIR="/tmp/${APP_NAME}-installer"
MANIFEST_DIR="${WORKDIR}/manifests"
IMAGE_DIR="${WORKDIR}/images"
IMAGE_JSON="${IMAGE_DIR}/image.json"
IMAGE_INDEX="${IMAGE_DIR}/image-index.tsv"
TEMPLATE_FILE="${MANIFEST_DIR}/metrics-server.yaml.tmpl"
RENDERED_MANIFEST="${WORKDIR}/rendered-metrics-server.yaml"

ACTION="install"
HELP_TOPIC=""
NAMESPACE="kube-system"
REPLICAS="1"
WAIT_TIMEOUT="5m"
AUTO_YES="false"
SKIP_IMAGE_PREPARE="false"
IMAGE_PULL_POLICY="IfNotPresent"
METRIC_RESOLUTION="15s"
KUBELET_PREFERRED_ADDRESS_TYPES="InternalIP,ExternalIP,Hostname"
KUBELET_INSECURE_TLS="false"
KUBELET_USE_NODE_STATUS_PORT="true"
HOST_NETWORK="false"
APISERVICE_INSECURE_SKIP_TLS_VERIFY="true"

REGISTRY_REPO="sealos.hub:5000/kube4"
REGISTRY_ADDR="sealos.hub:5000"
REGISTRY_USER="admin"
REGISTRY_PASS="passw0rd"
METRICS_SERVER_IMAGE_LOAD_REF=""
METRICS_SERVER_IMAGE_DEFAULT_REF=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() {
  echo -e "${CYAN}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

die() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

section() {
  echo
  echo "============================================================"
  echo "$*"
  echo "============================================================"
}

banner() {
  echo -e "${BOLD}Metrics Server Offline Installer${NC}"
  echo "Version: ${INSTALLER_VERSION}"
}

refresh_registry_addr() {
  if [[ "${REGISTRY_REPO}" == */* ]]; then
    REGISTRY_ADDR="${REGISTRY_REPO%%/*}"
  else
    REGISTRY_ADDR="${REGISTRY_REPO}"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  ./metrics-server-installer.run <action> [options]
  ./metrics-server-installer.run help

Actions:
  install      Install or reconcile metrics-server
  uninstall    Remove metrics-server resources
  status       Show current metrics-server status
  help         Show this message

Common options:
  -n, --namespace <ns>                 Default: kube-system
  --replicas <n>                       Default: 1
  --registry <repo-prefix>             Default: sealos.hub:5000/kube4
  --registry-user <user>               Default: admin
  --registry-pass <pass>               Default: passw0rd
  --skip-image-prepare                 Skip docker load/tag/push
  --image-pull-policy <policy>         Default: IfNotPresent
  --metric-resolution <duration>       Default: 15s
  --kubelet-preferred-address-types <types>
  --kubelet-insecure-tls               Allow skipping kubelet cert validation
  --host-network                       Run metrics-server with hostNetwork
  --wait-timeout <duration>            Default: 5m
  -y, --yes                            Skip confirmation

Examples:
  ./metrics-server-installer.run install -y
  ./metrics-server-installer.run install --kubelet-insecure-tls -y
  ./metrics-server-installer.run install --replicas 2 --host-network -y
  ./metrics-server-installer.run uninstall -y
  ./metrics-server-installer.run status
EOF
}

parse_action() {
  if [[ $# -eq 0 ]]; then
    ACTION="install"
    return
  fi

  case "$1" in
    install|uninstall|status)
      ACTION="$1"
      shift
      ;;
    help|-h|--help)
      ACTION="help"
      shift
      ;;
  esac

  parse_args "$@"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        NAMESPACE="$2"
        shift 2
        ;;
      --replicas)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REPLICAS="$2"
        shift 2
        ;;
      --registry)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_REPO="$2"
        refresh_registry_addr
        shift 2
        ;;
      --registry-user)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_USER="$2"
        shift 2
        ;;
      --registry-pass)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_PASS="$2"
        shift 2
        ;;
      --skip-image-prepare)
        SKIP_IMAGE_PREPARE="true"
        shift
        ;;
      --image-pull-policy)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        IMAGE_PULL_POLICY="$2"
        shift 2
        ;;
      --metric-resolution)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        METRIC_RESOLUTION="$2"
        shift 2
        ;;
      --kubelet-preferred-address-types)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        KUBELET_PREFERRED_ADDRESS_TYPES="$2"
        shift 2
        ;;
      --kubelet-insecure-tls)
        KUBELET_INSECURE_TLS="true"
        shift
        ;;
      --host-network)
        HOST_NETWORK="true"
        shift
        ;;
      --wait-timeout)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        WAIT_TIMEOUT="$2"
        shift 2
        ;;
      -y|--yes)
        AUTO_YES="true"
        shift
        ;;
      -h|--help)
        ACTION="help"
        shift
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

validate_inputs() {
  [[ -n "${NAMESPACE}" ]] || die "Namespace must not be empty"
  [[ "${REPLICAS}" =~ ^[0-9]+$ ]] || die "--replicas must be an integer"
  (( REPLICAS >= 1 )) || die "--replicas must be >= 1"

  case "${IMAGE_PULL_POLICY}" in
    Always|IfNotPresent|Never)
      ;;
    *)
      die "--image-pull-policy must be one of Always, IfNotPresent, Never"
      ;;
  esac
}

check_requirements() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl is required"

  case "${ACTION}" in
    install)
      command -v tar >/dev/null 2>&1 || die "tar is required"
      command -v awk >/dev/null 2>&1 || die "awk is required"
      command -v head >/dev/null 2>&1 || die "head is required"
      command -v tail >/dev/null 2>&1 || die "tail is required"
      command -v dd >/dev/null 2>&1 || die "dd is required"
      command -v od >/dev/null 2>&1 || die "od is required"
      if [[ "${SKIP_IMAGE_PREPARE}" != "true" ]]; then
        command -v docker >/dev/null 2>&1 || die "docker is required when image preparation is enabled"
      fi
      ;;
    uninstall)
      command -v tar >/dev/null 2>&1 || die "tar is required"
      command -v awk >/dev/null 2>&1 || die "awk is required"
      command -v head >/dev/null 2>&1 || die "head is required"
      command -v tail >/dev/null 2>&1 || die "tail is required"
      command -v dd >/dev/null 2>&1 || die "dd is required"
      command -v od >/dev/null 2>&1 || die "od is required"
      ;;
  esac
}

print_plan() {
  section "Execution Plan"
  echo "Action                    : ${ACTION}"
  echo "Namespace                 : ${NAMESPACE}"

  if [[ "${ACTION}" == "install" ]]; then
    echo "Replicas                  : ${REPLICAS}"
    echo "Registry                  : ${REGISTRY_REPO}"
    echo "Skip image prepare        : ${SKIP_IMAGE_PREPARE}"
    echo "Image pull policy         : ${IMAGE_PULL_POLICY}"
    echo "Metric resolution         : ${METRIC_RESOLUTION}"
    echo "Preferred address types   : ${KUBELET_PREFERRED_ADDRESS_TYPES}"
    echo "Kubelet insecure TLS      : ${KUBELET_INSECURE_TLS}"
    echo "Host network              : ${HOST_NETWORK}"
    echo "Wait timeout              : ${WAIT_TIMEOUT}"
  fi
}

confirm_plan() {
  [[ "${AUTO_YES}" == "true" ]] && return 0
  echo
  read -r -p "Continue? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES)
      ;;
    *)
      die "Cancelled"
      ;;
  esac
}

extract_payload() {
  section "Extract Payload"
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"

  local marker_line offset skip hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Unable to locate payload marker"

  offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip=0

  while :; do
    hex="$(dd if="$0" bs=1 skip="$((offset + skip - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${hex}" in
      0a|0d)
        skip=$((skip + 1))
        ;;
      "")
        die "Payload is empty"
        ;;
      *)
        break
        ;;
    esac
  done

  log "Extracting payload into ${WORKDIR}"
  tail -c +"$((offset + skip))" "$0" | tar -xzf - -C "${WORKDIR}" || die "Failed to extract payload"
  [[ -f "${TEMPLATE_FILE}" ]] || die "Payload is missing manifests/metrics-server.yaml.tmpl"
  [[ -f "${IMAGE_INDEX}" ]] || die "Payload is missing images/image-index.tsv"
  success "Payload extracted"
}

load_image_metadata() {
  if [[ -n "${METRICS_SERVER_IMAGE_DEFAULT_REF}" ]]; then
    return 0
  fi

  [[ -f "${IMAGE_INDEX}" ]] || extract_payload

  while IFS=$'\t' read -r _tar_name load_ref default_target_ref _platform _pull; do
    [[ -n "${default_target_ref}" ]] || continue
    METRICS_SERVER_IMAGE_LOAD_REF="${load_ref}"
    METRICS_SERVER_IMAGE_DEFAULT_REF="${default_target_ref}"
    return 0
  done < "${IMAGE_INDEX}"

  die "No metrics-server image metadata found in ${IMAGE_INDEX}"
}

docker_login() {
  log "Logging into registry ${REGISTRY_ADDR}"
  if echo "${REGISTRY_PASS}" | docker login "${REGISTRY_ADDR}" -u "${REGISTRY_USER}" --password-stdin >/dev/null 2>&1; then
    success "Registry login succeeded"
  else
    warn "Registry login failed, continuing"
  fi
}

resolve_target_image_tag() {
  local source_tag="$1"
  local suffix="${source_tag#*/kube4/}"

  if [[ "${suffix}" == "${source_tag}" ]]; then
    suffix="${source_tag##*/}"
  fi

  printf '%s/%s' "${REGISTRY_REPO}" "${suffix}"
}

prepare_images() {
  load_image_metadata
  [[ "${SKIP_IMAGE_PREPARE}" == "true" ]] && {
    warn "Skipping image prepare because --skip-image-prepare was requested"
    return 0
  }

  section "Prepare Offline Images"
  docker_login

  local count=0
  while IFS=$'\t' read -r tar_name load_ref default_target_ref _platform _pull; do
    [[ -n "${tar_name}" ]] || continue

    local target_tag tar_path
    target_tag="$(resolve_target_image_tag "${default_target_ref}")"
    tar_path="${IMAGE_DIR}/${tar_name}"

    [[ -f "${tar_path}" ]] || die "Missing image archive: ${tar_path}"

    log "Loading ${tar_name}"
    docker load -i "${tar_path}" >/dev/null
    if [[ "${target_tag}" != "${load_ref}" ]]; then
      log "Tagging ${load_ref} -> ${target_tag}"
      docker tag "${load_ref}" "${target_tag}"
    fi
    log "Pushing ${target_tag}"
    docker push "${target_tag}" >/dev/null
    count=$((count + 1))
  done < "${IMAGE_INDEX}"

  (( count > 0 )) || die "No image archives found in payload"
  success "Prepared ${count} image archive(s)"
}

ensure_namespace() {
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    return 0
  fi
  log "Creating namespace ${NAMESPACE}"
  kubectl create namespace "${NAMESPACE}" >/dev/null
}

template_replace() {
  local template="$1"
  local key="$2"
  local value="$3"
  template="${template//${key}/${value}}"
  printf '%s' "${template}"
}

metrics_server_image() {
  load_image_metadata
  resolve_target_image_tag "${METRICS_SERVER_IMAGE_DEFAULT_REF}"
}

render_manifest() {
  local template rendered
  local host_network_block=""
  local ha_anti_affinity_block=""
  local pdb_block=""
  local kubelet_insecure_tls_arg=""
  local kubelet_use_node_status_port_arg=""
  local max_unavailable="0"

  template="$(< "${TEMPLATE_FILE}")"

  if [[ "${HOST_NETWORK}" == "true" ]]; then
    host_network_block=$'      hostNetwork: true\n      dnsPolicy: ClusterFirstWithHostNet\n'
  fi

  if [[ "${KUBELET_INSECURE_TLS}" == "true" ]]; then
    kubelet_insecure_tls_arg=$'        - --kubelet-insecure-tls\n'
  fi

  if [[ "${KUBELET_USE_NODE_STATUS_PORT}" == "true" ]]; then
    kubelet_use_node_status_port_arg=$'        - --kubelet-use-node-status-port\n'
  fi

  if (( REPLICAS > 1 )); then
    max_unavailable="1"
    ha_anti_affinity_block=$'      affinity:\n        podAntiAffinity:\n          requiredDuringSchedulingIgnoredDuringExecution:\n          - labelSelector:\n              matchLabels:\n                k8s-app: metrics-server\n            namespaces:\n            - '"${NAMESPACE}"$'\n            topologyKey: kubernetes.io/hostname\n'
    pdb_block=$'---\napiVersion: policy/v1\nkind: PodDisruptionBudget\nmetadata:\n  labels:\n    k8s-app: metrics-server\n  name: metrics-server\n  namespace: '"${NAMESPACE}"$'\nspec:\n  minAvailable: 1\n  selector:\n    matchLabels:\n      k8s-app: metrics-server\n'
  fi

  rendered="${template}"
  rendered="$(template_replace "${rendered}" "__NAMESPACE__" "${NAMESPACE}")"
  rendered="$(template_replace "${rendered}" "__REPLICAS__" "${REPLICAS}")"
  rendered="$(template_replace "${rendered}" "__MAX_UNAVAILABLE__" "${max_unavailable}")"
  rendered="$(template_replace "${rendered}" "__HOST_NETWORK_BLOCK__" "${host_network_block}")"
  rendered="$(template_replace "${rendered}" "__HA_ANTI_AFFINITY_BLOCK__" "${ha_anti_affinity_block}")"
  rendered="$(template_replace "${rendered}" "__KUBELET_USE_NODE_STATUS_PORT_ARG__" "${kubelet_use_node_status_port_arg}")"
  rendered="$(template_replace "${rendered}" "__KUBELET_INSECURE_TLS_ARG__" "${kubelet_insecure_tls_arg}")"
  rendered="$(template_replace "${rendered}" "__KUBELET_PREFERRED_ADDRESS_TYPES__" "${KUBELET_PREFERRED_ADDRESS_TYPES}")"
  rendered="$(template_replace "${rendered}" "__METRIC_RESOLUTION__" "${METRIC_RESOLUTION}")"
  rendered="$(template_replace "${rendered}" "__METRICS_SERVER_IMAGE__" "$(metrics_server_image)")"
  rendered="$(template_replace "${rendered}" "__IMAGE_PULL_POLICY__" "${IMAGE_PULL_POLICY}")"
  rendered="$(template_replace "${rendered}" "__PDB_BLOCK__" "${pdb_block}")"
  rendered="$(template_replace "${rendered}" "__APISERVICE_INSECURE_SKIP_TLS_VERIFY__" "${APISERVICE_INSECURE_SKIP_TLS_VERIFY}")"

  printf '%s' "${rendered}" > "${RENDERED_MANIFEST}"
}

wait_for_ready() {
  section "Wait For Readiness"
  kubectl rollout status deployment/metrics-server -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"

  if kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout="${WAIT_TIMEOUT}" >/dev/null 2>&1; then
    success "APIService is Available"
  else
    warn "APIService is not Available yet; recheck with: kubectl get apiservice v1beta1.metrics.k8s.io"
  fi
}

install_app() {
  extract_payload
  prepare_images
  ensure_namespace
  render_manifest

  section "Install / Reconcile metrics-server"
  kubectl apply -f "${RENDERED_MANIFEST}"
  wait_for_ready
  success "metrics-server install/reconcile completed"
}

uninstall_app() {
  extract_payload
  render_manifest

  section "Uninstall metrics-server"
  kubectl delete -f "${RENDERED_MANIFEST}" --ignore-not-found=true >/dev/null || true
  success "metrics-server uninstall completed"
}

show_status() {
  section "metrics-server Status"
  kubectl get deployment metrics-server -n "${NAMESPACE}" -o wide 2>/dev/null || warn "Deployment metrics-server not found"
  kubectl get pods -n "${NAMESPACE}" -l k8s-app=metrics-server -o wide 2>/dev/null || true
  kubectl get svc metrics-server -n "${NAMESPACE}" 2>/dev/null || true
  kubectl get apiservice v1beta1.metrics.k8s.io -o wide 2>/dev/null || warn "APIService v1beta1.metrics.k8s.io not found"

  echo
  echo "Useful checks:"
  echo "  kubectl top nodes"
  echo "  kubectl top pods -A"
  echo "  kubectl logs -n ${NAMESPACE} deploy/metrics-server"
}

cleanup() {
  rm -rf "${WORKDIR}" >/dev/null 2>&1 || true
}

main() {
  trap cleanup EXIT
  refresh_registry_addr
  banner
  parse_action "$@"

  if [[ "${ACTION}" == "help" ]]; then
    usage
    exit 0
  fi

  validate_inputs
  check_requirements

  if [[ "${ACTION}" != "status" ]]; then
    print_plan
    confirm_plan
  fi

  case "${ACTION}" in
    install)
      install_app
      ;;
    uninstall)
      uninstall_app
      ;;
    status)
      show_status
      ;;
    *)
      die "Unsupported action: ${ACTION}"
      ;;
  esac
}

main "$@"

exit 0
__PAYLOAD_BELOW__
