#!/usr/bin/env bash
# Bootstrap / self-update entrypoint for infra-bot.
#
# First install (from a laptop clone, no network fetch needed):
#   sudo ./scripts/install.sh
#
# First install on a host (private GitHub repo via token):
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/get-infra-bot.sh \
#     | sudo env GITHUB_TOKEN=ghp_xxx bash
#
# Or with git+SSH access already configured on the host:
#   sudo env INFRA_BOT_REPO_URL=git@github.com:owner/repo.git bash get-infra-bot.sh
#
# Later updates on any installed host:
#   sudo infra-bot-update

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib/common.sh
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
  source "${SCRIPT_DIR}/lib/common.sh"
else
  log() { printf '[infra-bot] %s\n' "$*"; }
  warn() { printf '[infra-bot] warning: %s\n' "$*" >&2; }
  die() { printf '[infra-bot] error: %s\n' "$*" >&2; exit 1; }
  command_exists() { command -v "$1" >/dev/null 2>&1; }
fi

APP_HOME="/opt/infra-bot"
CONFIG_DIR="/etc/infra-bot"
INSTALL_CONF="${CONFIG_DIR}/install.conf"
DEFAULT_REPO_SLUG="${INFRA_BOT_REPO_SLUG:-ashraftown/infra-bot}"
DEFAULT_REPO_REF="${INFRA_BOT_REF:-main}"
DEFAULT_REPO_URL="${INFRA_BOT_REPO_URL:-}"

MODE="install"
LOCAL_ONLY=0
EXTRA_INSTALL_ARGS=()
WORKDIR=""
CLEANUP_WORKDIR=0

usage() {
  cat <<'EOF'
Usage: get-infra-bot.sh [install|update] [options]

Commands:
  install   Fresh install (default). Interactive unless flags/env provide values.
  update    Refresh code from GitHub/git, reinstall package, keep host config.

Options:
  --local                 Use source next to this script (no network fetch)
  --repo-slug OWNER/REPO  GitHub repo slug (default: ashraftown/infra-bot)
  --ref REF               Git ref/branch/tag (default: main)
  --repo-url URL          git clone URL (SSH or HTTPS)
  --token TOKEN           GitHub token for private repo tarball download
  --help

Any additional options are passed through to scripts/install.sh
(for example --server-name, --non-interactive, --stagger-minutes).

Environment:
  GITHUB_TOKEN / INFRA_BOT_GITHUB_TOKEN
  INFRA_BOT_REPO_SLUG
  INFRA_BOT_REF
  INFRA_BOT_REPO_URL
EOF
}

load_install_conf() {
  [[ -f "${INSTALL_CONF}" ]] || return 0
  # shellcheck disable=SC1090
  source "${INSTALL_CONF}"
  DEFAULT_REPO_SLUG="${REPO_SLUG:-$DEFAULT_REPO_SLUG}"
  DEFAULT_REPO_REF="${REPO_REF:-$DEFAULT_REPO_REF}"
  DEFAULT_REPO_URL="${REPO_URL:-$DEFAULT_REPO_URL}"
  if [[ -z "${GITHUB_TOKEN:-}" && -n "${INFRA_BOT_GITHUB_TOKEN:-}" ]]; then
    GITHUB_TOKEN="${INFRA_BOT_GITHUB_TOKEN}"
  fi
  if [[ -z "${GITHUB_TOKEN:-}" && -n "${GITHUB_TOKEN_FROM_CONF:-}" ]]; then
    GITHUB_TOKEN="${GITHUB_TOKEN_FROM_CONF}"
  fi
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      install|update)
        MODE="$1"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local)
        LOCAL_ONLY=1
        shift
        ;;
      --repo-slug)
        DEFAULT_REPO_SLUG="${2:-}"
        shift 2
        ;;
      --ref)
        DEFAULT_REPO_REF="${2:-}"
        shift 2
        ;;
      --repo-url)
        DEFAULT_REPO_URL="${2:-}"
        shift 2
        ;;
      --token)
        GITHUB_TOKEN="${2:-}"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        EXTRA_INSTALL_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."
}

cleanup() {
  if [[ "${CLEANUP_WORKDIR}" -eq 1 && -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
    rm -rf "${WORKDIR}"
  fi
}

is_repo_tree() {
  local candidate="$1"
  [[ -n "${candidate}" \
    && -f "${candidate}/pyproject.toml" \
    && -d "${candidate}/infra_bot" \
    && -f "${candidate}/scripts/install.sh" ]]
}

local_repo_root() {
  local candidate="${SCRIPT_DIR}/.."
  candidate="$(cd "${candidate}" && pwd)"
  if is_repo_tree "${candidate}"; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  return 1
}

invoking_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "${SUDO_USER}"
    return 0
  fi
  return 1
}

user_home() {
  local user="$1"
  getent passwd "${user}" | awk -F: '{print $6}'
}

find_user_checkout() {
  local user=""
  local home=""
  local candidate=""
  user="$(invoking_user)" || return 1
  home="$(user_home "${user}")"
  [[ -n "${home}" ]] || return 1
  for candidate in \
    "${home}/infra-bot" \
    "${home}/codebase/infra-bot" \
    "${home}/src/infra-bot"; do
    if is_repo_tree "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

ensure_fetch_tools() {
  command_exists tar || die "tar is required"
  if command_exists curl || command_exists git; then
    return 0
  fi
  die "Need curl and/or git to download infra-bot source. On Ubuntu: sudo apt-get install -y git curl"
}

source_tree_ok() {
  local dest_dir="$1"
  is_repo_tree "${dest_dir}"
}

download_github_tarball() {
  local slug="$1"
  local ref="$2"
  local dest_dir="$3"
  local token="${GITHUB_TOKEN:-${INFRA_BOT_GITHUB_TOKEN:-}}"
  local url="https://api.github.com/repos/${slug}/tarball/${ref}"
  local archive="${dest_dir}.tgz"
  local curl_args=(-fsSL -H "Accept: application/vnd.github+json" -L)

  [[ -n "${token}" ]] || return 1
  command_exists curl || return 1

  log "Downloading ${slug}@${ref}"
  curl_args+=(-H "Authorization: Bearer ${token}")
  curl_args+=(-H "X-GitHub-Api-Version: 2022-11-28")
  if ! curl "${curl_args[@]}" "${url}" -o "${archive}"; then
    warn "GitHub tarball download failed for ${slug}@${ref}"
    rm -f "${archive}"
    return 1
  fi

  mkdir -p "${dest_dir}"
  if ! tar -xzf "${archive}" -C "${dest_dir}" --strip-components=1; then
    warn "Failed to extract GitHub tarball"
    rm -rf "${dest_dir}" "${archive}"
    mkdir -p "${dest_dir}"
    return 1
  fi
  rm -f "${archive}"
  source_tree_ok "${dest_dir}"
}

# Run a git command either as root or as the sudo-invoking user so their
# SSH keys / known_hosts are used for private GitHub access.
run_git() {
  local user=""
  if user="$(invoking_user)" && [[ "$(id -u)" -eq 0 ]]; then
    # -H sets HOME so ssh finds /home/<user>/.ssh (root's keys usually lack GitHub access).
    sudo -u "${user}" -H git "$@"
    return $?
  fi
  git "$@"
}

clone_git_repo() {
  local url="$1"
  local ref="$2"
  local dest_dir="$3"

  command_exists git || return 1
  [[ -n "${url}" ]] || return 1
  rm -rf "${dest_dir}"

  log "Fetching ${url} @ ${ref}"
  if run_git clone --quiet --depth 1 --branch "${ref}" "${url}" "${dest_dir}"; then
    :
  elif run_git clone --quiet --depth 1 "${url}" "${dest_dir}"; then
    run_git -C "${dest_dir}" checkout "${ref}" >/dev/null 2>&1 || true
  else
    warn "git clone failed for ${url}"
    rm -rf "${dest_dir}"
    mkdir -p "${dest_dir}"
    return 1
  fi

  if ! source_tree_ok "${dest_dir}"; then
    warn "Clone at ${dest_dir} is missing expected infra-bot files"
    rm -rf "${dest_dir}"
    mkdir -p "${dest_dir}"
    return 1
  fi
  return 0
}

refresh_user_checkout() {
  local checkout="$1"
  local user=""
  user="$(invoking_user)" || true

  if [[ ! -d "${checkout}/.git" ]]; then
    log "Using existing checkout at ${checkout} (not a git repo; no pull)"
    return 0
  fi
  if ! command_exists git; then
    warn "git is not installed; using checkout as-is at ${checkout}"
    return 0
  fi

  log "Refreshing local checkout at ${checkout}"
  if run_git -C "${checkout}" fetch --depth 1 origin "${DEFAULT_REPO_REF}"; then
    run_git -C "${checkout}" checkout "${DEFAULT_REPO_REF}" >/dev/null 2>&1 || true
    run_git -C "${checkout}" pull --ff-only origin "${DEFAULT_REPO_REF}" >/dev/null 2>&1 \
      || run_git -C "${checkout}" reset --hard "origin/${DEFAULT_REPO_REF}" >/dev/null 2>&1 \
      || warn "Could not fast-forward ${checkout}; installing whatever is currently checked out"
  else
    warn "git fetch failed for ${checkout}; installing whatever is currently checked out"
  fi

  # Ensure root-run installer can read files owned by the invoking user.
  if [[ "$(id -u)" -eq 0 && -n "${user}" ]]; then
    chmod -R a+rX "${checkout}" 2>/dev/null || true
  fi
  source_tree_ok "${checkout}"
}

fetch_source() {
  local dest="$1"

  if download_github_tarball "${DEFAULT_REPO_SLUG}" "${DEFAULT_REPO_REF}" "${dest}"; then
    return 0
  fi

  if [[ -n "${DEFAULT_REPO_URL}" ]] && clone_git_repo "${DEFAULT_REPO_URL}" "${DEFAULT_REPO_REF}" "${dest}"; then
    return 0
  fi

  # Common SSH default when only the slug is known.
  if clone_git_repo "git@github.com:${DEFAULT_REPO_SLUG}.git" "${DEFAULT_REPO_REF}" "${dest}"; then
    return 0
  fi

  if clone_git_repo "https://github.com/${DEFAULT_REPO_SLUG}.git" "${DEFAULT_REPO_REF}" "${dest}"; then
    return 0
  fi

  return 1
}

auth_help_message() {
  cat <<EOF
Could not download ${DEFAULT_REPO_SLUG}@${DEFAULT_REPO_REF}.

Private GitHub access is required. Pick one:

  1) GitHub token (recommended for sudo infra-bot-update as root):
       sudo env INFRA_BOT_GITHUB_TOKEN=ghp_xxx infra-bot-update

  2) SSH key available to the user who runs sudo (keys in ~/.ssh):
       ssh -T git@github.com    # must work as that user first
       sudo infra-bot-update

  3) Local checkout (works offline / without root GitHub auth):
       cd ~/infra-bot && git pull
       sudo ./scripts/install.sh --update
       # or: sudo infra-bot-update --local   (from inside the checkout)

  4) Host missing git entirely:
       sudo apt-get install -y git
EOF
}

resolve_source_tree() {
  local local_root=""
  local user_checkout=""

  if [[ "${LOCAL_ONLY}" -eq 1 ]]; then
    if local_root="$(local_repo_root)"; then
      WORKDIR="${local_root}"
    elif user_checkout="$(find_user_checkout)"; then
      WORKDIR="${user_checkout}"
    else
      die "--local requires an infra-bot checkout next to this script or in ~/infra-bot"
    fi
    CLEANUP_WORKDIR=0
    log "Using local source at ${WORKDIR}"
    return
  fi

  # install from an existing checkout when this script lives in the repo and
  # the user did not force a remote fetch.
  if [[ "${MODE}" == "install" ]] && local_root="$(local_repo_root)"; then
    WORKDIR="${local_root}"
    CLEANUP_WORKDIR=0
    log "Using local source at ${WORKDIR}"
    return
  fi

  ensure_fetch_tools
  WORKDIR="$(mktemp -d /tmp/infra-bot-src.XXXXXX)"
  CLEANUP_WORKDIR=1

  if fetch_source "${WORKDIR}"; then
    return
  fi

  # Fall back to the invoking user's existing checkout (common on these hosts).
  if user_checkout="$(find_user_checkout)"; then
    rm -rf "${WORKDIR}"
    CLEANUP_WORKDIR=0
    WORKDIR="${user_checkout}"
    refresh_user_checkout "${WORKDIR}" || true
    if source_tree_ok "${WORKDIR}"; then
      log "Using local checkout ${WORKDIR}"
      return
    fi
  fi

  auth_help_message >&2
  die "Update aborted: no usable source tree."
}

run_installer() {
  local installer="${WORKDIR}/scripts/install.sh"
  [[ -x "${installer}" || -f "${installer}" ]] || die "Missing installer at ${installer}"
  chmod +x "${installer}" || true

  if [[ "${MODE}" == "update" ]]; then
    # shellcheck disable=SC2086
    bash "${installer}" --update "${EXTRA_INSTALL_ARGS[@]+"${EXTRA_INSTALL_ARGS[@]}"}"
    return
  fi

  log "Running installer"
  # shellcheck disable=SC2086
  bash "${installer}" "${EXTRA_INSTALL_ARGS[@]+"${EXTRA_INSTALL_ARGS[@]}"}"
}

main() {
  trap cleanup EXIT
  load_install_conf
  # Prefer explicit env token over conf.
  if [[ -n "${INFRA_BOT_GITHUB_TOKEN:-}" ]]; then
    GITHUB_TOKEN="${INFRA_BOT_GITHUB_TOKEN}"
  fi
  parse_args "$@"
  require_root
  resolve_source_tree
  run_installer
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
