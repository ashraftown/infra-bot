#!/usr/bin/env bash
# Remote bootstrap for infra-bot (safe for: curl ... | sudo bash)
#
# Primary install path:
#   curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash
#
# With installer flags:
#   curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash -s -- --server-name web-01
#
# Update an existing host (same URL):
#   curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash -s -- update

set -euo pipefail

REPO_SLUG="${INFRA_BOT_REPO_SLUG:-ashraftown/infra-bot}"
REPO_REF="${INFRA_BOT_REF:-main}"
REPO_URL="${INFRA_BOT_REPO_URL:-https://github.com/${REPO_SLUG}.git}"
CODELOAD_URL="https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/heads/${REPO_REF}"
# Tag/commit refs also work via the archive endpoint:
ARCHIVE_URL="https://github.com/${REPO_SLUG}/archive/refs/heads/${REPO_REF}.tar.gz"

WORKDIR=""
CLEANUP=0

log() { printf '[infra-bot] %s\n' "$*"; }
warn() { printf '[infra-bot] warning: %s\n' "$*" >&2; }
die() { printf '[infra-bot] error: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ "${CLEANUP}" -eq 1 && -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (this script is intended for: curl ... | sudo bash)."
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_tools() {
  local need=()
  command_exists curl || need+=("curl")
  command_exists tar || need+=("tar")
  # git is optional but preferred for clone
  if ! command_exists git; then
    need+=("git")
  fi
  if ! command_exists python3; then
    need+=("python3" "python3-venv" "python3-pip")
  fi

  if ((${#need[@]} == 0)); then
    return 0
  fi

  command_exists apt-get || die "apt-get is required (Ubuntu/Debian). Missing: ${need[*]}"
  log "Installing prerequisites: ${need[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
}

is_repo_tree() {
  local dir="$1"
  [[ -f "${dir}/pyproject.toml" && -d "${dir}/infra_bot" && -f "${dir}/scripts/install.sh" ]]
}

fetch_via_git() {
  local dest="$1"
  command_exists git || return 1
  log "Cloning ${REPO_URL} @ ${REPO_REF}"
  if git clone --quiet --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${dest}" 2>/dev/null; then
    is_repo_tree "${dest}"
    return $?
  fi
  if git clone --quiet --depth 1 "${REPO_URL}" "${dest}" 2>/dev/null; then
    git -C "${dest}" checkout "${REPO_REF}" >/dev/null 2>&1 || true
    is_repo_tree "${dest}"
    return $?
  fi
  return 1
}

fetch_via_tarball() {
  local dest="$1"
  local archive="${dest}.tgz"
  command_exists curl || return 1
  command_exists tar || return 1

  log "Downloading ${REPO_SLUG}@${REPO_REF} archive"
  if ! curl -fsSL "${ARCHIVE_URL}" -o "${archive}" 2>/dev/null \
    && ! curl -fsSL "${CODELOAD_URL}" -o "${archive}" 2>/dev/null; then
    rm -f "${archive}"
    return 1
  fi

  mkdir -p "${dest}"
  # GitHub archives extract to <repo>-<ref>/...
  if ! tar -xzf "${archive}" -C "${dest}" --strip-components=1 2>/dev/null; then
    rm -rf "${dest}" "${archive}"
    return 1
  fi
  rm -f "${archive}"
  is_repo_tree "${dest}"
}

fetch_source() {
  WORKDIR="$(mktemp -d /tmp/infra-bot-bootstrap.XXXXXX)"
  CLEANUP=1

  if fetch_via_git "${WORKDIR}"; then
    return 0
  fi
  rm -rf "${WORKDIR}"
  WORKDIR="$(mktemp -d /tmp/infra-bot-bootstrap.XXXXXX)"

  if fetch_via_tarball "${WORKDIR}"; then
    return 0
  fi

  die "Could not download ${REPO_SLUG}@${REPO_REF}. Check network access to GitHub, or set INFRA_BOT_REPO_URL."
}

usage() {
  cat <<'EOF'
infra-bot bootstrap

Usage:
  curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash
  curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash -s -- [install|update] [install.sh flags...]

Examples:
  curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash
  curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash -s -- --server-name node1 --stagger-minutes 15
  curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash -s -- update

Environment:
  INFRA_BOT_REPO_SLUG   default: ashraftown/infra-bot
  INFRA_BOT_REF         default: main
  INFRA_BOT_REPO_URL    default: https://github.com/<slug>.git
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_root
  ensure_tools

  local mode="install"
  local -a passthrough=()

  if [[ "${1:-}" == "install" || "${1:-}" == "update" ]]; then
    mode="$1"
    shift
  fi
  passthrough=("$@")

  log "Bootstrap starting (${mode})"
  log "Source: ${REPO_SLUG}@${REPO_REF}"
  fetch_source

  local installer="${WORKDIR}/scripts/install.sh"
  [[ -f "${installer}" ]] || die "Downloaded tree is missing scripts/install.sh"
  chmod +x "${installer}" || true

  if [[ "${mode}" == "update" ]]; then
    log "Running update (config preserved)"
    bash "${installer}" --update "${passthrough[@]+"${passthrough[@]}"}"
  else
    log "Running installer"
    bash "${installer}" "${passthrough[@]+"${passthrough[@]}"}"
  fi
}

main "$@"
