#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_FILE="${ROOT_DIR}/payload.tar.gz"
TEMP_DIR="${ROOT_DIR}/.build-payload"
IMAGES_DIR="${ROOT_DIR}/images"
MANIFESTS_DIR="${ROOT_DIR}/manifests"
DIST_DIR="${ROOT_DIR}/dist"
IMAGE_JSON="${IMAGES_DIR}/image.json"

ARCH="amd64"
PLATFORM="linux/amd64"
BUILD_ALL="false"
INSTALLER_NAME=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() {
  echo -e "${CYAN}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

die() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./build.sh [--arch amd64|arm64|all]

Examples:
  ./build.sh --arch amd64
  ./build.sh --arch arm64
  ./build.sh --arch all
EOF
}

normalize_arch() {
  case "$1" in
    amd64|amd|x86_64)
      ARCH="amd64"
      PLATFORM="linux/amd64"
      BUILD_ALL="false"
      ;;
    arm64|arm|aarch64)
      ARCH="arm64"
      PLATFORM="linux/arm64"
      BUILD_ALL="false"
      ;;
    all)
      BUILD_ALL="true"
      ;;
    *)
      die "Unsupported arch: $1"
      ;;
  esac

  INSTALLER_NAME="metrics-server-installer-${ARCH}.run"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch|-a)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        normalize_arch "$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

check_requirements() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || die "python or python3 is required"
  [[ -f "${ROOT_DIR}/install.sh" ]] || die "install.sh is missing"
  [[ -d "${MANIFESTS_DIR}" ]] || die "manifests directory is missing"
  [[ -d "${IMAGES_DIR}" ]] || die "images directory is missing"
  [[ -f "${IMAGE_JSON}" ]] || die "images/image.json is missing"
  grep -q '^__PAYLOAD_BELOW__$' "${ROOT_DIR}/install.sh" || die "install.sh is missing __PAYLOAD_BELOW__ marker"
}

python_cmd() {
  if command -v python >/dev/null 2>&1; then
    printf 'python'
  else
    printf 'python3'
  fi
}

prepare_directories() {
  rm -rf "${TEMP_DIR}" "${PAYLOAD_FILE}"
  mkdir -p "${TEMP_DIR}/images" "${TEMP_DIR}/manifests" "${DIST_DIR}"
}

write_image_metadata() {
  local arch="$1"
  local output_json="$2"
  local output_index="$3"
  "$(python_cmd)" - "${IMAGE_JSON}" "${arch}" "${output_json}" "${output_index}" <<'PY'
import json
import sys

source_path, arch, output_json, output_index = sys.argv[1:]

with open(source_path, "r", encoding="utf-8") as fh:
    items = json.load(fh)

selected = [dict(item) for item in items if item.get("arch") == arch]
if not selected:
    raise SystemExit(f"no image definition found for arch={arch}")

with open(output_json, "w", encoding="utf-8") as fh:
    json.dump(selected, fh, ensure_ascii=False, indent=2)
    fh.write("\n")

with open(output_index, "w", encoding="utf-8", newline="") as fh:
    for item in selected:
        default_target_ref = item.get("tag") or item.get("pull") or ""
        fh.write("\t".join([
            item.get("tar", ""),
            default_target_ref,
            default_target_ref,
            item.get("platform", ""),
            item.get("pull", ""),
        ]) + "\n")
PY
}

prepare_images() {
  local count=0
  local payload_image_json="${TEMP_DIR}/images/image.json"
  local payload_image_index="${TEMP_DIR}/images/image-index.tsv"

  write_image_metadata "${ARCH}" "${payload_image_json}" "${payload_image_index}"

  while IFS=$'\t' read -r tar_name load_ref default_target_ref platform pull; do
    [[ -n "${tar_name}" ]] || continue
    [[ -n "${platform}" ]] || platform="${PLATFORM}"

    log "Pull ${pull} (${platform})"
    docker pull --platform "${platform}" "${pull}"

    if [[ "${pull}" != "${default_target_ref}" ]]; then
      log "Tag ${pull} -> ${default_target_ref}"
      docker tag "${pull}" "${default_target_ref}"
    fi

    log "Save ${default_target_ref} -> ${TEMP_DIR}/images/${tar_name}"
    docker save -o "${TEMP_DIR}/images/${tar_name}" "${default_target_ref}"
    count=$((count + 1))
  done < "${payload_image_index}"

  (( count > 0 )) || die "No image definition found for arch=${ARCH}"
  log "Preparing ${count} image(s) for ${ARCH}"
}

package_payload() {
  log "Packaging manifests and images"
  cp -r "${MANIFESTS_DIR}/"* "${TEMP_DIR}/manifests/"

  (
    cd "${TEMP_DIR}"
    tar -czf "${PAYLOAD_FILE}" .
  )

  tar -tzf "${PAYLOAD_FILE}" >/dev/null 2>&1 || die "Payload verification failed"
}

build_installer() {
  local installer_path="${DIST_DIR}/${INSTALLER_NAME}"
  cat "${ROOT_DIR}/install.sh" "${PAYLOAD_FILE}" > "${installer_path}"
  chmod +x "${installer_path}"
  sha256sum "${installer_path}" > "${installer_path}.sha256"
  success "Built ${installer_path}"
  echo "  sha256: ${installer_path}.sha256"
}

cleanup() {
  rm -rf "${TEMP_DIR}" "${PAYLOAD_FILE}" >/dev/null 2>&1 || true
}

build_one() {
  normalize_arch "$1"

  echo -e "${BOLD}Metrics Server Offline Installer Builder${NC}"
  echo "  arch: ${ARCH}"
  echo "  platform: ${PLATFORM}"

  prepare_directories
  prepare_images
  package_payload
  build_installer
}

main() {
  trap cleanup EXIT
  normalize_arch "${ARCH}"
  parse_args "$@"
  check_requirements

  if [[ "${BUILD_ALL}" == "true" ]]; then
    build_one amd64
    build_one arm64
  else
    build_one "${ARCH}"
  fi
}

main "$@"
