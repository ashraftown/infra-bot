#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP_HOME="/opt/infra-bot"
VENV_DIR="${APP_HOME}/.venv"
SRC_DIR="${APP_HOME}/src"
CONFIG_DIR="/etc/infra-bot"
CONFIG_PATH="${CONFIG_DIR}/config.yaml"
STATE_DIR="/var/lib/infra-bot"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_USER="infra-bot"
SERVICE_GROUP="infra-bot"
DEFAULT_SERVER_NAME="web-01"
DEFAULT_ALLOWED_CHAT_IDS="123456789"
DEFAULT_POLL_TIMEOUT="30"
DEFAULT_SCHEDULE="Sun 02:00"
DEFAULT_STAGGER="0"
DEFAULT_USE_DIST_UPGRADE="true"
DEFAULT_AUTOREMOVE="true"
DEFAULT_REBOOT_GRACE="5"
NON_INTERACTIVE=0
FORCE=0

SERVER_NAME=""
BOT_TOKEN=""
ALLOWED_CHAT_IDS=""
STAGGER_MINUTES=""
POLL_TIMEOUT_SECONDS=""
USE_DIST_UPGRADE=""
AUTOREMOVE=""
REBOOT_GRACE_MINUTES=""

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/install.sh [options]

Options:
  --non-interactive
  --server-name VALUE
  --bot-token VALUE
  --allowed-chat-ids VALUE
  --stagger-minutes VALUE
  --force
  --help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      --server-name)
        SERVER_NAME="${2:-}"
        shift 2
        ;;
      --bot-token)
        BOT_TOKEN="${2:-}"
        shift 2
        ;;
      --allowed-chat-ids)
        ALLOWED_CHAT_IDS="${2:-}"
        shift 2
        ;;
      --stagger-minutes)
        STAGGER_MINUTES="${2:-}"
        shift 2
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this installer as root."
}

validate_repo() {
  [[ -f "${REPO_ROOT}/pyproject.toml" ]] || die "Missing pyproject.toml in ${REPO_ROOT}"
  [[ -d "${REPO_ROOT}/infra_bot" ]] || die "Missing infra_bot package in ${REPO_ROOT}"
  [[ -d "${REPO_ROOT}/deploy/systemd" ]] || die "Missing deploy/systemd in ${REPO_ROOT}"
}

check_os() {
  [[ -f /etc/os-release ]] || die "Missing /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
    return
  fi
  if [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]]; then
    warn "Detected ${PRETTY_NAME:-unknown}; installer is optimized for Ubuntu 24.04."
    if [[ "${FORCE}" -eq 1 || "${NON_INTERACTIVE}" -eq 1 ]]; then
      [[ "${FORCE}" -eq 1 ]] || die "Unsupported OS in non-interactive mode without --force."
      return
    fi
    prompt_yes_no "Continue anyway?" "N" || die "Aborted on unsupported OS."
    return
  fi

  if [[ "${FORCE}" -eq 1 ]]; then
    warn "Continuing on unsupported OS: ${PRETTY_NAME:-unknown}"
    return
  fi
  die "Unsupported OS: ${PRETTY_NAME:-unknown}. Re-run with --force to continue."
}

ensure_base_commands() {
  command_exists apt-get || die "apt-get is required"
  command_exists systemctl || die "systemctl is required"
}

install_prereqs() {
  local packages=()
  if ! command_exists python3; then
    packages+=("python3" "python3-venv" "python3-pip")
  else
    python3 -m venv --help >/dev/null 2>&1 || packages+=("python3-venv")
    python3 -m pip --version >/dev/null 2>&1 || packages+=("python3-pip")
  fi

  if (( ${#packages[@]} > 0 )); then
    log "Installing prerequisites: ${packages[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  fi
}

read_existing_value() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  awk -F': ' -v wanted="$key" '$1 == wanted {gsub(/"/, "", $2); print $2; exit}' "$file"
}

read_existing_chat_ids() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^  allowed_chat_ids:/ { in_list=1; next }
    in_list && /^    - / {
      gsub(/^    - /, "", $0)
      values = values ? values "," $0 : $0
      next
    }
    in_list { exit }
    END { print values }
  ' "$file"
}

load_existing_defaults() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    return
  fi
  DEFAULT_SERVER_NAME="$(read_existing_value "server_name" "${CONFIG_PATH}")"
  DEFAULT_SERVER_NAME="${DEFAULT_SERVER_NAME:-web-01}"
  DEFAULT_ALLOWED_CHAT_IDS="$(read_existing_chat_ids "${CONFIG_PATH}")"
  DEFAULT_ALLOWED_CHAT_IDS="${DEFAULT_ALLOWED_CHAT_IDS:-123456789}"
  DEFAULT_POLL_TIMEOUT="$(read_existing_value "  poll_timeout_seconds" "${CONFIG_PATH}")"
  DEFAULT_POLL_TIMEOUT="${DEFAULT_POLL_TIMEOUT:-30}"
  DEFAULT_SCHEDULE="$(read_existing_value "  schedule" "${CONFIG_PATH}")"
  DEFAULT_SCHEDULE="${DEFAULT_SCHEDULE:-Sun 02:00}"
  DEFAULT_STAGGER="$(read_existing_value "  stagger_minutes" "${CONFIG_PATH}")"
  DEFAULT_STAGGER="${DEFAULT_STAGGER:-0}"
  DEFAULT_USE_DIST_UPGRADE="$(read_existing_value "  use_dist_upgrade" "${CONFIG_PATH}")"
  DEFAULT_USE_DIST_UPGRADE="${DEFAULT_USE_DIST_UPGRADE:-true}"
  DEFAULT_AUTOREMOVE="$(read_existing_value "  autoremove" "${CONFIG_PATH}")"
  DEFAULT_AUTOREMOVE="${DEFAULT_AUTOREMOVE:-true}"
  DEFAULT_REBOOT_GRACE="$(read_existing_value "  grace_minutes" "${CONFIG_PATH}")"
  DEFAULT_REBOOT_GRACE="${DEFAULT_REBOOT_GRACE:-5}"
  DEFAULT_BOT_TOKEN="$(read_existing_value "  bot_token" "${CONFIG_PATH}")"
}

normalize_bool() {
  local value="${1,,}"
  case "$value" in
    y|yes|true|1) printf 'true\n' ;;
    n|no|false|0) printf 'false\n' ;;
    *) return 1 ;;
  esac
}

validate_chat_ids() {
  local raw="$1"
  local normalized=""
  IFS=',' read -r -a ids <<< "$raw"
  for id in "${ids[@]}"; do
    id="$(trim_spaces "$id")"
    [[ -n "$id" ]] || continue
    [[ "$id" =~ ^-?[0-9]+$ ]] || return 1
    normalized="${normalized:+${normalized},}${id}"
  done
  [[ -n "$normalized" ]] || return 1
  printf '%s\n' "$normalized"
}

validate_required_inputs() {
  [[ -n "${SERVER_NAME}" ]] || die "Server name is required."
  [[ -n "${BOT_TOKEN}" ]] || die "Telegram bot token is required."
  ALLOWED_CHAT_IDS="$(validate_chat_ids "${ALLOWED_CHAT_IDS}")" || die "Allowed chat IDs must be comma-separated integers."
  [[ "${STAGGER_MINUTES}" =~ ^[0-9]+$ ]] || die "Stagger minutes must be a non-negative integer."
  [[ "${POLL_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || die "Poll timeout must be a non-negative integer."
  [[ "${REBOOT_GRACE_MINUTES}" =~ ^[0-9]+$ ]] || die "Reboot grace minutes must be a non-negative integer."
  USE_DIST_UPGRADE="$(normalize_bool "${USE_DIST_UPGRADE}")" || die "Invalid dist-upgrade value."
  AUTOREMOVE="$(normalize_bool "${AUTOREMOVE}")" || die "Invalid autoremove value."
}

collect_inputs() {
  load_existing_defaults

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    SERVER_NAME="${SERVER_NAME:-$DEFAULT_SERVER_NAME}"
    BOT_TOKEN="${BOT_TOKEN:-${DEFAULT_BOT_TOKEN:-}}"
    ALLOWED_CHAT_IDS="${ALLOWED_CHAT_IDS:-$DEFAULT_ALLOWED_CHAT_IDS}"
    STAGGER_MINUTES="${STAGGER_MINUTES:-$DEFAULT_STAGGER}"
    POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-$DEFAULT_POLL_TIMEOUT}"
    USE_DIST_UPGRADE="${USE_DIST_UPGRADE:-$DEFAULT_USE_DIST_UPGRADE}"
    AUTOREMOVE="${AUTOREMOVE:-$DEFAULT_AUTOREMOVE}"
    REBOOT_GRACE_MINUTES="${REBOOT_GRACE_MINUTES:-$DEFAULT_REBOOT_GRACE}"
    validate_required_inputs
    return
  fi

  while [[ -z "${SERVER_NAME}" ]]; do
    SERVER_NAME="$(prompt_with_default "Server name" "${DEFAULT_SERVER_NAME}")"
  done

  while [[ -z "${BOT_TOKEN}" ]]; do
    BOT_TOKEN="$(prompt_secret "Telegram bot token" "${DEFAULT_BOT_TOKEN:-}")"
    [[ -n "${BOT_TOKEN}" ]] || warn "Telegram bot token is required."
  done

  while true; do
    ALLOWED_CHAT_IDS="$(prompt_with_default "Allowed chat IDs (comma separated)" "${DEFAULT_ALLOWED_CHAT_IDS}")"
    if ALLOWED_CHAT_IDS="$(validate_chat_ids "${ALLOWED_CHAT_IDS}")"; then
      break
    fi
    warn "Chat IDs must be comma-separated integers."
  done

  while true; do
    STAGGER_MINUTES="$(prompt_with_default "Weekly stagger minutes" "${DEFAULT_STAGGER}")"
    if [[ "${STAGGER_MINUTES}" =~ ^[0-9]+$ ]]; then
      if [[ "${STAGGER_MINUTES}" != "0" && "${STAGGER_MINUTES}" != "15" && "${STAGGER_MINUTES}" != "30" ]]; then
        warn "Typical values are 0, 15, or 30 minutes."
        prompt_yes_no "Use ${STAGGER_MINUTES} minutes anyway?" "N" || continue
      fi
      break
    fi
    warn "Stagger minutes must be a non-negative integer."
  done

  while true; do
    POLL_TIMEOUT_SECONDS="$(prompt_with_default "Telegram poll timeout seconds" "${DEFAULT_POLL_TIMEOUT}")"
    [[ "${POLL_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] && break
    warn "Poll timeout must be a non-negative integer."
  done

  if prompt_yes_no "Use dist-upgrade?" "$( [[ "${DEFAULT_USE_DIST_UPGRADE}" == "true" ]] && printf 'Y' || printf 'N' )"; then
    USE_DIST_UPGRADE="true"
  else
    USE_DIST_UPGRADE="false"
  fi

  if prompt_yes_no "Run autoremove --purge?" "$( [[ "${DEFAULT_AUTOREMOVE}" == "true" ]] && printf 'Y' || printf 'N' )"; then
    AUTOREMOVE="true"
  else
    AUTOREMOVE="false"
  fi

  while true; do
    REBOOT_GRACE_MINUTES="$(prompt_with_default "Reboot grace minutes" "${DEFAULT_REBOOT_GRACE}")"
    [[ "${REBOOT_GRACE_MINUTES}" =~ ^[0-9]+$ ]] && break
    warn "Reboot grace minutes must be a non-negative integer."
  done
}

render_summary() {
  cat <<EOF
Install summary
  Repo root: ${REPO_ROOT}
  App home: ${APP_HOME}
  Config: ${CONFIG_PATH}
  Server name: ${SERVER_NAME}
  Telegram bot token: $(mask_secret "${BOT_TOKEN}")
  Allowed chat IDs: ${ALLOWED_CHAT_IDS}
  Schedule: ${DEFAULT_SCHEDULE}
  Stagger minutes: ${STAGGER_MINUTES}
  Poll timeout seconds: ${POLL_TIMEOUT_SECONDS}
  Use dist-upgrade: ${USE_DIST_UPGRADE}
  Run autoremove --purge: ${AUTOREMOVE}
  Reboot grace minutes: ${REBOOT_GRACE_MINUTES}
EOF
}

confirm_summary() {
  render_summary
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    return
  fi
  prompt_yes_no "Proceed with installation?" "Y" || die "Installation cancelled."
}

create_user_and_dirs() {
  if ! getent group "${SERVICE_GROUP}" >/dev/null 2>&1; then
    groupadd --system "${SERVICE_GROUP}"
  fi

  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd --system --home "${APP_HOME}" --gid "${SERVICE_GROUP}" --shell /usr/sbin/nologin "${SERVICE_USER}"
  fi

  install -d -m 0755 -o root -g root "${APP_HOME}" "${SRC_DIR}" "${CONFIG_DIR}"
  install -d -m 0750 -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" "${STATE_DIR}"
}

sync_source_tree() {
  if command_exists rsync; then
    rsync -a --delete \
      --exclude '.git' \
      --exclude '.pytest_cache' \
      --exclude '.venv' \
      --exclude '__pycache__' \
      "${REPO_ROOT}/" "${SRC_DIR}/"
    return
  fi

  rm -rf "${SRC_DIR}"
  mkdir -p "${SRC_DIR}"
  cp -R "${REPO_ROOT}/." "${SRC_DIR}/"
  rm -rf "${SRC_DIR}/.git" "${SRC_DIR}/.pytest_cache" "${SRC_DIR}/.venv"
  find "${SRC_DIR}" -type d -name '__pycache__' -prune -exec rm -rf {} +
}

install_python_package() {
  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install --upgrade pip
  "${VENV_DIR}/bin/pip" install "${SRC_DIR}"
}

render_config() {
  local chat_yaml=""
  IFS=',' read -r -a ids <<< "${ALLOWED_CHAT_IDS}"
  for id in "${ids[@]}"; do
    id="$(trim_spaces "$id")"
    chat_yaml="${chat_yaml}    - ${id}"$'\n'
  done

  cat <<EOF
server_name: ${SERVER_NAME}
telegram:
  bot_token: "${BOT_TOKEN}"
  allowed_chat_ids:
${chat_yaml}  poll_timeout_seconds: ${POLL_TIMEOUT_SECONDS}
update_policy:
  schedule: "${DEFAULT_SCHEDULE}"
  stagger_minutes: ${STAGGER_MINUTES}
  use_dist_upgrade: ${USE_DIST_UPGRADE}
  autoremove: ${AUTOREMOVE}
reboot_policy:
  mode: "scheduled_if_required"
  grace_minutes: ${REBOOT_GRACE_MINUTES}
paths:
  state_file: "/var/lib/infra-bot/state.json"
  reboot_marker_file: "/var/run/reboot-required"
EOF
}

write_config() {
  render_config > "${CONFIG_PATH}"
  chown root:root "${CONFIG_PATH}"
  chmod 0600 "${CONFIG_PATH}"

  if command_exists setfacl; then
    setfacl -m "u:${SERVICE_USER}:r" "${CONFIG_PATH}"
  else
    warn "setfacl not available; falling back to group-readable config permissions."
    chown root:"${SERVICE_GROUP}" "${CONFIG_PATH}"
    chmod 0640 "${CONFIG_PATH}"
  fi
}

compute_calendar() {
  local total_minutes=$(( 2 * 60 + STAGGER_MINUTES ))
  local hour=$(( total_minutes / 60 ))
  local minute=$(( total_minutes % 60 ))
  printf 'Sun *-*-* %02d:%02d:00\n' "${hour}" "${minute}"
}

write_service_units() {
  local bot_bin="${VENV_DIR}/bin/infra-bot"
  cat > "${SYSTEMD_DIR}/infra-bot.service" <<EOF
[Unit]
Description=Infra Bot Telegram polling service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bot_bin} --config ${CONFIG_PATH} run-bot
Restart=always
RestartSec=5
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${SRC_DIR}
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

  cat > "${SYSTEMD_DIR}/infra-bot-update.service" <<EOF
[Unit]
Description=Infra Bot weekly package update runner
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${bot_bin} --config ${CONFIG_PATH} run-update
User=root
Group=root
WorkingDirectory=${SRC_DIR}
Environment=PYTHONUNBUFFERED=1
EOF

  cat > "${SYSTEMD_DIR}/infra-bot-update.timer" <<EOF
[Unit]
Description=Infra Bot weekly update timer

[Timer]
OnCalendar=$(compute_calendar)
Persistent=true
RandomizedDelaySec=0
Unit=infra-bot-update.service

[Install]
WantedBy=timers.target
EOF
}

activate_services() {
  systemctl daemon-reload
  systemctl enable infra-bot.service >/dev/null
  systemctl enable infra-bot-update.timer >/dev/null
  systemctl restart infra-bot.service
  systemctl restart infra-bot-update.timer
}

verify_install() {
  systemctl is-active infra-bot.service >/dev/null || die "infra-bot.service is not active."
  systemctl is-enabled infra-bot-update.timer >/dev/null || die "infra-bot-update.timer is not enabled."

  log "Installation complete."
  printf '\nFollow-up commands:\n'
  printf '  systemctl status infra-bot.service\n'
  printf '  systemctl list-timers infra-bot-update.timer\n'
  printf '  %s --config %s status\n' "${VENV_DIR}/bin/infra-bot" "${CONFIG_PATH}"
}

main() {
  parse_args "$@"
  require_root
  validate_repo
  check_os
  ensure_base_commands
  install_prereqs
  collect_inputs
  validate_required_inputs
  confirm_summary
  create_user_and_dirs
  sync_source_tree
  install_python_package
  write_config
  write_service_units
  activate_services
  verify_install
}

main "$@"
