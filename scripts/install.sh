#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP_HOME="/opt/infra-bot"
VENV_DIR="${APP_HOME}/.venv"
SRC_DIR="${APP_HOME}/src"
BIN_DIR="${APP_HOME}/bin"
CONFIG_DIR="/etc/infra-bot"
CONFIG_PATH="${CONFIG_DIR}/config.yaml"
INSTALL_CONF="${CONFIG_DIR}/install.conf"
STATE_DIR="/var/lib/infra-bot"
SYSTEMD_DIR="/etc/systemd/system"
UPDATE_COMMAND_PATH="/usr/local/sbin/infra-bot-update"
SERVICE_USER="infra-bot"
SERVICE_GROUP="infra-bot"
DEFAULT_SERVER_NAME="web-01"
DEFAULT_MESSAGING_MODE="telegram"
DEFAULT_ALLOWED_CHAT_IDS="123456789"
DEFAULT_POLL_TIMEOUT="30"
DEFAULT_SLACK_ALLOWED_USER_IDS="U12345678"
DEFAULT_SLACK_CHANNEL_IDS="C12345678"
DEFAULT_SLACK_COMMAND_NAME="/infra-bot"
DEFAULT_SCHEDULE="Sun 02:00"
DEFAULT_STAGGER="0"
DEFAULT_USE_DIST_UPGRADE="true"
DEFAULT_AUTOREMOVE="true"
DEFAULT_REBOOT_GRACE="5"
DEFAULT_REPO_SLUG="${INFRA_BOT_REPO_SLUG:-ashraftown/infra-bot}"
DEFAULT_REPO_REF="${INFRA_BOT_REF:-main}"
DEFAULT_REPO_URL="${INFRA_BOT_REPO_URL:-}"
NON_INTERACTIVE=0
FORCE=0
UPDATE_MODE=0
KEEP_CONFIG=0

SERVER_NAME=""
MESSAGING_MODE=""
TELEGRAM_BOT_TOKEN=""
ALLOWED_CHAT_IDS=""
POLL_TIMEOUT_SECONDS=""
SLACK_BOT_TOKEN=""
SLACK_APP_TOKEN=""
SLACK_ALLOWED_USER_IDS=""
SLACK_CHANNEL_IDS=""
SLACK_COMMAND_NAME=""
STAGGER_MINUTES=""
USE_DIST_UPGRADE=""
AUTOREMOVE=""
REBOOT_GRACE_MINUTES=""

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/install.sh [options]

Options:
  --update                 Refresh code/package/units; keep existing config
  --non-interactive
  --server-name VALUE
  --messaging-mode telegram|slack|both
  --telegram-bot-token VALUE
  --bot-token VALUE
  --allowed-chat-ids VALUE
  --slack-bot-token VALUE
  --slack-app-token VALUE
  --slack-allowed-user-ids VALUE
  --slack-channel-ids VALUE
  --slack-command-name VALUE
  --stagger-minutes VALUE
  --repo-slug OWNER/REPO
  --ref REF
  --repo-url URL
  --force
  --help

Typical day-2 usage on an already-installed host:
  sudo infra-bot-update
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --update)
        UPDATE_MODE=1
        KEEP_CONFIG=1
        NON_INTERACTIVE=1
        shift
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      --server-name)
        SERVER_NAME="${2:-}"
        shift 2
        ;;
      --messaging-mode)
        MESSAGING_MODE="${2:-}"
        shift 2
        ;;
      --telegram-bot-token|--bot-token)
        TELEGRAM_BOT_TOKEN="${2:-}"
        shift 2
        ;;
      --allowed-chat-ids)
        ALLOWED_CHAT_IDS="${2:-}"
        shift 2
        ;;
      --slack-bot-token)
        SLACK_BOT_TOKEN="${2:-}"
        shift 2
        ;;
      --slack-app-token)
        SLACK_APP_TOKEN="${2:-}"
        shift 2
        ;;
      --slack-allowed-user-ids)
        SLACK_ALLOWED_USER_IDS="${2:-}"
        shift 2
        ;;
      --slack-channel-ids)
        SLACK_CHANNEL_IDS="${2:-}"
        shift 2
        ;;
      --slack-command-name)
        SLACK_COMMAND_NAME="${2:-}"
        shift 2
        ;;
      --stagger-minutes)
        STAGGER_MINUTES="${2:-}"
        shift 2
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

read_existing_root_value() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  awk -v wanted="$key" '
    $0 ~ "^[^[:space:]][^:]*:[[:space:]]*" && $1 == wanted ":" {
      line = $0
      sub("^[^:]+:[[:space:]]*", "", line)
      gsub(/"/, "", line)
      print line
      exit
    }
  ' "$file"
}

read_existing_section_value() {
  local section="$1"
  local key="$2"
  local file="$3"
  [[ -f "$file" ]] || return 0
  awk -v section="$section" -v wanted="$key" '
    /^[^[:space:]].*:$/ {
      in_section = ($0 == section ":")
      next
    }
    in_section && /^[^[:space:]].*:/ { exit }
    in_section && $0 ~ ("^  " wanted ":[[:space:]]*") {
      line = $0
      sub("^  " wanted ":[[:space:]]*", "", line)
      gsub(/"/, "", line)
      print line
      exit
    }
  ' "$file"
}

read_existing_section_list() {
  local section="$1"
  local key="$2"
  local file="$3"
  [[ -f "$file" ]] || return 0
  awk -v section="$section" -v wanted="$key" '
    /^[^[:space:]].*:$/ {
      if (in_section && $0 != section ":") {
        exit
      }
      in_section = ($0 == section ":")
      in_list = 0
      next
    }
    in_section && $0 ~ ("^  " wanted ":$") {
      in_list = 1
      next
    }
    in_section && in_list && /^    - / {
      line = $0
      sub(/^    - /, "", line)
      values = values ? values "," line : line
      next
    }
    in_section && in_list {
      exit
    }
    END {
      print values
    }
  ' "$file"
}

load_existing_defaults() {
  local existing_mode=""
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    return
  fi

  DEFAULT_SERVER_NAME="$(read_existing_root_value "server_name" "${CONFIG_PATH}")"
  DEFAULT_SERVER_NAME="${DEFAULT_SERVER_NAME:-web-01}"

  existing_mode="$(read_existing_section_value "messaging" "mode" "${CONFIG_PATH}")"
  DEFAULT_MESSAGING_MODE="${existing_mode:-telegram}"

  DEFAULT_ALLOWED_CHAT_IDS="$(read_existing_section_list "telegram" "allowed_chat_ids" "${CONFIG_PATH}")"
  DEFAULT_ALLOWED_CHAT_IDS="${DEFAULT_ALLOWED_CHAT_IDS:-123456789}"
  DEFAULT_POLL_TIMEOUT="$(read_existing_section_value "telegram" "poll_timeout_seconds" "${CONFIG_PATH}")"
  DEFAULT_POLL_TIMEOUT="${DEFAULT_POLL_TIMEOUT:-30}"
  DEFAULT_TELEGRAM_BOT_TOKEN="$(read_existing_section_value "telegram" "bot_token" "${CONFIG_PATH}")"

  DEFAULT_SLACK_ALLOWED_USER_IDS="$(read_existing_section_list "slack" "allowed_user_ids" "${CONFIG_PATH}")"
  DEFAULT_SLACK_ALLOWED_USER_IDS="${DEFAULT_SLACK_ALLOWED_USER_IDS:-U12345678}"
  DEFAULT_SLACK_CHANNEL_IDS="$(read_existing_section_list "slack" "notification_channel_ids" "${CONFIG_PATH}")"
  DEFAULT_SLACK_CHANNEL_IDS="${DEFAULT_SLACK_CHANNEL_IDS:-C12345678}"
  DEFAULT_SLACK_COMMAND_NAME="$(read_existing_section_value "slack" "command_name" "${CONFIG_PATH}")"
  DEFAULT_SLACK_COMMAND_NAME="${DEFAULT_SLACK_COMMAND_NAME:-/infra-bot}"
  DEFAULT_SLACK_BOT_TOKEN="$(read_existing_section_value "slack" "bot_token" "${CONFIG_PATH}")"
  DEFAULT_SLACK_APP_TOKEN="$(read_existing_section_value "slack" "app_token" "${CONFIG_PATH}")"

  DEFAULT_SCHEDULE="$(read_existing_section_value "update_policy" "schedule" "${CONFIG_PATH}")"
  DEFAULT_SCHEDULE="${DEFAULT_SCHEDULE:-Sun 02:00}"
  DEFAULT_STAGGER="$(read_existing_section_value "update_policy" "stagger_minutes" "${CONFIG_PATH}")"
  DEFAULT_STAGGER="${DEFAULT_STAGGER:-0}"
  DEFAULT_USE_DIST_UPGRADE="$(read_existing_section_value "update_policy" "use_dist_upgrade" "${CONFIG_PATH}")"
  DEFAULT_USE_DIST_UPGRADE="${DEFAULT_USE_DIST_UPGRADE:-true}"
  DEFAULT_AUTOREMOVE="$(read_existing_section_value "update_policy" "autoremove" "${CONFIG_PATH}")"
  DEFAULT_AUTOREMOVE="${DEFAULT_AUTOREMOVE:-true}"
  DEFAULT_REBOOT_GRACE="$(read_existing_section_value "reboot_policy" "grace_minutes" "${CONFIG_PATH}")"
  DEFAULT_REBOOT_GRACE="${DEFAULT_REBOOT_GRACE:-5}"
}

normalize_bool() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    y|yes|true|1) printf 'true\n' ;;
    n|no|false|0) printf 'false\n' ;;
    *) return 1 ;;
  esac
}

validate_messaging_mode() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    telegram|slack|both) printf '%s\n' "$value" ;;
    *) return 1 ;;
  esac
}

validate_chat_ids() {
  local raw="$1"
  local normalized=""
  local id=""
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

validate_string_list() {
  local raw="$1"
  local normalized=""
  local value=""
  IFS=',' read -r -a values <<< "$raw"
  for value in "${values[@]}"; do
    value="$(trim_spaces "$value")"
    [[ -n "$value" ]] || continue
    normalized="${normalized:+${normalized},}${value}"
  done
  [[ -n "$normalized" ]] || return 1
  printf '%s\n' "$normalized"
}

uses_telegram() {
  [[ "${MESSAGING_MODE}" == "telegram" || "${MESSAGING_MODE}" == "both" ]]
}

uses_slack() {
  [[ "${MESSAGING_MODE}" == "slack" || "${MESSAGING_MODE}" == "both" ]]
}

validate_required_inputs() {
  [[ -n "${SERVER_NAME}" ]] || die "Server name is required."
  MESSAGING_MODE="$(validate_messaging_mode "${MESSAGING_MODE}")" || die "Messaging mode must be telegram, slack, or both."
  [[ "${STAGGER_MINUTES}" =~ ^[0-9]+$ ]] || die "Stagger minutes must be a non-negative integer."
  [[ "${REBOOT_GRACE_MINUTES}" =~ ^[0-9]+$ ]] || die "Reboot grace minutes must be a non-negative integer."
  USE_DIST_UPGRADE="$(normalize_bool "${USE_DIST_UPGRADE}")" || die "Invalid dist-upgrade value."
  AUTOREMOVE="$(normalize_bool "${AUTOREMOVE}")" || die "Invalid autoremove value."

  if uses_telegram; then
    [[ -n "${TELEGRAM_BOT_TOKEN}" ]] || die "Telegram bot token is required."
    ALLOWED_CHAT_IDS="$(validate_chat_ids "${ALLOWED_CHAT_IDS}")" || die "Allowed chat IDs must be comma-separated integers."
    [[ "${POLL_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || die "Poll timeout must be a non-negative integer."
  else
    ALLOWED_CHAT_IDS=""
    POLL_TIMEOUT_SECONDS=""
  fi

  if uses_slack; then
    [[ -n "${SLACK_BOT_TOKEN}" ]] || die "Slack bot token is required."
    [[ -n "${SLACK_APP_TOKEN}" ]] || die "Slack app token is required."
    SLACK_ALLOWED_USER_IDS="$(validate_string_list "${SLACK_ALLOWED_USER_IDS}")" || die "Allowed Slack user IDs must be comma-separated values."
    SLACK_CHANNEL_IDS="$(validate_string_list "${SLACK_CHANNEL_IDS}")" || die "Slack channel IDs must be comma-separated values."
    SLACK_COMMAND_NAME="${SLACK_COMMAND_NAME:-/infra-bot}"
    [[ "${SLACK_COMMAND_NAME}" == /* ]] || die "Slack command name must start with '/'."
  else
    SLACK_ALLOWED_USER_IDS=""
    SLACK_CHANNEL_IDS=""
    SLACK_COMMAND_NAME=""
  fi
}

collect_inputs() {
  load_existing_defaults

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    SERVER_NAME="${SERVER_NAME:-$DEFAULT_SERVER_NAME}"
    MESSAGING_MODE="${MESSAGING_MODE:-$DEFAULT_MESSAGING_MODE}"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${DEFAULT_TELEGRAM_BOT_TOKEN:-}}"
    ALLOWED_CHAT_IDS="${ALLOWED_CHAT_IDS:-$DEFAULT_ALLOWED_CHAT_IDS}"
    POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-$DEFAULT_POLL_TIMEOUT}"
    SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-${DEFAULT_SLACK_BOT_TOKEN:-}}"
    SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-${DEFAULT_SLACK_APP_TOKEN:-}}"
    SLACK_ALLOWED_USER_IDS="${SLACK_ALLOWED_USER_IDS:-$DEFAULT_SLACK_ALLOWED_USER_IDS}"
    SLACK_CHANNEL_IDS="${SLACK_CHANNEL_IDS:-$DEFAULT_SLACK_CHANNEL_IDS}"
    SLACK_COMMAND_NAME="${SLACK_COMMAND_NAME:-$DEFAULT_SLACK_COMMAND_NAME}"
    STAGGER_MINUTES="${STAGGER_MINUTES:-$DEFAULT_STAGGER}"
    USE_DIST_UPGRADE="${USE_DIST_UPGRADE:-$DEFAULT_USE_DIST_UPGRADE}"
    AUTOREMOVE="${AUTOREMOVE:-$DEFAULT_AUTOREMOVE}"
    REBOOT_GRACE_MINUTES="${REBOOT_GRACE_MINUTES:-$DEFAULT_REBOOT_GRACE}"
    validate_required_inputs
    return
  fi

  while [[ -z "${SERVER_NAME}" ]]; do
    SERVER_NAME="$(prompt_with_default "Server name" "${DEFAULT_SERVER_NAME}")"
  done

  while true; do
    MESSAGING_MODE="$(prompt_with_default "Messaging mode (telegram, slack, both)" "${DEFAULT_MESSAGING_MODE}")"
    if MESSAGING_MODE="$(validate_messaging_mode "${MESSAGING_MODE}")"; then
      break
    fi
    warn "Messaging mode must be telegram, slack, or both."
  done

  if uses_telegram; then
    while [[ -z "${TELEGRAM_BOT_TOKEN}" ]]; do
      TELEGRAM_BOT_TOKEN="$(prompt_secret "Telegram bot token" "${DEFAULT_TELEGRAM_BOT_TOKEN:-}")"
      [[ -n "${TELEGRAM_BOT_TOKEN}" ]] || warn "Telegram bot token is required."
    done

    while true; do
      ALLOWED_CHAT_IDS="$(prompt_with_default "Allowed chat IDs (comma separated)" "${DEFAULT_ALLOWED_CHAT_IDS}")"
      if ALLOWED_CHAT_IDS="$(validate_chat_ids "${ALLOWED_CHAT_IDS}")"; then
        break
      fi
      warn "Chat IDs must be comma-separated integers."
    done

    while true; do
      POLL_TIMEOUT_SECONDS="$(prompt_with_default "Telegram poll timeout seconds" "${DEFAULT_POLL_TIMEOUT}")"
      [[ "${POLL_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] && break
      warn "Poll timeout must be a non-negative integer."
    done
  fi

  if uses_slack; then
    while [[ -z "${SLACK_BOT_TOKEN}" ]]; do
      SLACK_BOT_TOKEN="$(prompt_secret "Slack bot token" "${DEFAULT_SLACK_BOT_TOKEN:-}")"
      [[ -n "${SLACK_BOT_TOKEN}" ]] || warn "Slack bot token is required."
    done

    while [[ -z "${SLACK_APP_TOKEN}" ]]; do
      SLACK_APP_TOKEN="$(prompt_secret "Slack app token" "${DEFAULT_SLACK_APP_TOKEN:-}")"
      [[ -n "${SLACK_APP_TOKEN}" ]] || warn "Slack app token is required."
    done

    while true; do
      SLACK_ALLOWED_USER_IDS="$(prompt_with_default "Allowed Slack user IDs (comma separated)" "${DEFAULT_SLACK_ALLOWED_USER_IDS}")"
      if SLACK_ALLOWED_USER_IDS="$(validate_string_list "${SLACK_ALLOWED_USER_IDS}")"; then
        break
      fi
      warn "Allowed Slack user IDs must be comma-separated values."
    done

    while true; do
      SLACK_CHANNEL_IDS="$(prompt_with_default "Slack notification channel IDs (comma separated)" "${DEFAULT_SLACK_CHANNEL_IDS}")"
      if SLACK_CHANNEL_IDS="$(validate_string_list "${SLACK_CHANNEL_IDS}")"; then
        break
      fi
      warn "Slack channel IDs must be comma-separated values."
    done

    while true; do
      SLACK_COMMAND_NAME="$(prompt_with_default "Slack slash command name" "${DEFAULT_SLACK_COMMAND_NAME}")"
      if [[ -n "${SLACK_COMMAND_NAME}" && "${SLACK_COMMAND_NAME}" == /* ]]; then
        break
      fi
      warn "Slack command name must start with '/'."
    done
  fi

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
  Messaging mode: ${MESSAGING_MODE}
EOF

  if uses_telegram; then
    cat <<EOF
  Telegram bot token: $(mask_secret "${TELEGRAM_BOT_TOKEN}")
  Allowed chat IDs: ${ALLOWED_CHAT_IDS}
  Poll timeout seconds: ${POLL_TIMEOUT_SECONDS}
EOF
  fi

  if uses_slack; then
    cat <<EOF
  Slack bot token: $(mask_secret "${SLACK_BOT_TOKEN}")
  Slack app token: $(mask_secret "${SLACK_APP_TOKEN}")
  Allowed Slack user IDs: ${SLACK_ALLOWED_USER_IDS}
  Slack channel IDs: ${SLACK_CHANNEL_IDS}
  Slack command name: ${SLACK_COMMAND_NAME}
EOF
  fi

  cat <<EOF
  Schedule: ${DEFAULT_SCHEDULE}
  Stagger minutes: ${STAGGER_MINUTES}
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

  install -d -m 0755 -o root -g root "${APP_HOME}" "${SRC_DIR}" "${BIN_DIR}" "${CONFIG_DIR}"
  install -d -m 0750 -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" "${STATE_DIR}"
}

detect_repo_metadata() {
  if [[ -z "${DEFAULT_REPO_URL}" ]] && command_exists git && [[ -d "${REPO_ROOT}/.git" ]]; then
    DEFAULT_REPO_URL="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
  fi

  if [[ -z "${DEFAULT_REPO_SLUG}" || "${DEFAULT_REPO_SLUG}" == "ashraftown/infra-bot" ]]; then
    if [[ "${DEFAULT_REPO_URL}" =~ github.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
      DEFAULT_REPO_SLUG="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    fi
  fi

  if command_exists git && [[ -d "${REPO_ROOT}/.git" ]]; then
    local current_ref
    current_ref="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ -n "${current_ref}" && "${current_ref}" != "HEAD" ]]; then
      DEFAULT_REPO_REF="${INFRA_BOT_REF:-${current_ref}}"
    fi
  fi
}

write_install_conf() {
  detect_repo_metadata
  local token_line=""
  # Persist token only when explicitly provided via env for unattended host updates.
  if [[ -n "${INFRA_BOT_GITHUB_TOKEN:-}" ]]; then
    token_line="GITHUB_TOKEN_FROM_CONF=\"${INFRA_BOT_GITHUB_TOKEN}\""
  elif [[ -f "${INSTALL_CONF}" ]]; then
    # Preserve previously stored token when re-running install/update.
    token_line="$(awk -F= '/^GITHUB_TOKEN_FROM_CONF=/{print; exit}' "${INSTALL_CONF}" || true)"
  fi

  cat > "${INSTALL_CONF}" <<EOF
# Managed by infra-bot installer. Used by: sudo infra-bot-update
REPO_SLUG="${DEFAULT_REPO_SLUG}"
REPO_REF="${DEFAULT_REPO_REF}"
REPO_URL="${DEFAULT_REPO_URL}"
${token_line}
EOF
  chown root:root "${INSTALL_CONF}"
  chmod 0600 "${INSTALL_CONF}"
}

install_update_helper() {
  install -d -m 0755 -o root -g root "${BIN_DIR}"
  install -m 0755 "${REPO_ROOT}/scripts/get-infra-bot.sh" "${BIN_DIR}/get-infra-bot.sh"
  if [[ -d "${REPO_ROOT}/scripts/lib" ]]; then
    rm -rf "${BIN_DIR}/lib"
    mkdir -p "${BIN_DIR}/lib"
    cp -R "${REPO_ROOT}/scripts/lib/." "${BIN_DIR}/lib/"
  fi

  cat > "${UPDATE_COMMAND_PATH}" <<EOF
#!/usr/bin/env bash
# Refresh infra-bot from the configured GitHub/git source and reinstall.
set -euo pipefail
exec "${BIN_DIR}/get-infra-bot.sh" update "\$@"
EOF
  chmod 0755 "${UPDATE_COMMAND_PATH}"
}

sync_source_tree() {
  if [[ "${UPDATE_MODE}" -eq 1 ]]; then
    log "Syncing application files"
  fi
  if command_exists rsync; then
    rsync -a --delete \
      --exclude '.git' \
      --exclude '.pytest_cache' \
      --exclude '.venv' \
      --exclude '__pycache__' \
      --exclude 'infra_bot.egg-info' \
      "${REPO_ROOT}/" "${SRC_DIR}/"
    return
  fi

  rm -rf "${SRC_DIR}"
  mkdir -p "${SRC_DIR}"
  cp -R "${REPO_ROOT}/." "${SRC_DIR}/"
  rm -rf "${SRC_DIR}/.git" "${SRC_DIR}/.pytest_cache" "${SRC_DIR}/.venv" "${SRC_DIR}/infra_bot.egg-info"
  find "${SRC_DIR}" -type d -name '__pycache__' -prune -exec rm -rf {} +
}

run_pip_quiet() {
  local log_file
  log_file="$(mktemp /tmp/infra-bot-pip.XXXXXX.log)"
  if ! "$@" >"${log_file}" 2>&1; then
    warn "Command failed: $*"
    cat "${log_file}" >&2 || true
    rm -f "${log_file}"
    return 1
  fi
  rm -f "${log_file}"
  return 0
}

install_python_package() {
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    log "Creating virtualenv"
    python3 -m venv "${VENV_DIR}"
  fi

  if [[ "${UPDATE_MODE}" -eq 1 ]]; then
    log "Installing package"
    run_pip_quiet "${VENV_DIR}/bin/pip" install -q --upgrade pip || die "Failed to upgrade pip"
    run_pip_quiet "${VENV_DIR}/bin/pip" install -q --upgrade "${SRC_DIR}" || die "Failed to install infra-bot package"
    return
  fi

  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install --upgrade pip
  "${VENV_DIR}/bin/pip" install "${SRC_DIR}"
}

source_revision() {
  if command_exists git && [[ -d "${REPO_ROOT}/.git" ]]; then
    git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || true
    return
  fi
  if [[ -f "${REPO_ROOT}/pyproject.toml" ]]; then
    awk -F'"' '/^version[[:space:]]*=/{print $2; exit}' "${REPO_ROOT}/pyproject.toml" 2>/dev/null || true
  fi
}

load_runtime_settings_from_config() {
  [[ -f "${CONFIG_PATH}" ]] || die "Missing config at ${CONFIG_PATH}. Run a full install first."
  load_existing_defaults
  SERVER_NAME="${SERVER_NAME:-$DEFAULT_SERVER_NAME}"
  MESSAGING_MODE="${MESSAGING_MODE:-$DEFAULT_MESSAGING_MODE}"
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${DEFAULT_TELEGRAM_BOT_TOKEN:-}}"
  ALLOWED_CHAT_IDS="${ALLOWED_CHAT_IDS:-$DEFAULT_ALLOWED_CHAT_IDS}"
  POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-$DEFAULT_POLL_TIMEOUT}"
  SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-${DEFAULT_SLACK_BOT_TOKEN:-}}"
  SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-${DEFAULT_SLACK_APP_TOKEN:-}}"
  SLACK_ALLOWED_USER_IDS="${SLACK_ALLOWED_USER_IDS:-$DEFAULT_SLACK_ALLOWED_USER_IDS}"
  SLACK_CHANNEL_IDS="${SLACK_CHANNEL_IDS:-$DEFAULT_SLACK_CHANNEL_IDS}"
  SLACK_COMMAND_NAME="${SLACK_COMMAND_NAME:-$DEFAULT_SLACK_COMMAND_NAME}"
  STAGGER_MINUTES="${STAGGER_MINUTES:-$DEFAULT_STAGGER}"
  USE_DIST_UPGRADE="${USE_DIST_UPGRADE:-$DEFAULT_USE_DIST_UPGRADE}"
  AUTOREMOVE="${AUTOREMOVE:-$DEFAULT_AUTOREMOVE}"
  REBOOT_GRACE_MINUTES="${REBOOT_GRACE_MINUTES:-$DEFAULT_REBOOT_GRACE}"
  validate_required_inputs
}

render_list_yaml() {
  local csv="$1"
  local indent="$2"
  local value=""
  local yaml=""
  IFS=',' read -r -a values <<< "${csv}"
  for value in "${values[@]}"; do
    value="$(trim_spaces "$value")"
    yaml="${yaml}${indent}- ${value}"$'\n'
  done
  printf '%s' "$yaml"
}

render_config() {
  cat <<EOF
server_name: ${SERVER_NAME}
messaging:
  mode: "${MESSAGING_MODE}"
EOF

  if uses_telegram; then
    cat <<EOF
telegram:
  bot_token: "${TELEGRAM_BOT_TOKEN}"
  allowed_chat_ids:
$(render_list_yaml "${ALLOWED_CHAT_IDS}" "    ")
  poll_timeout_seconds: ${POLL_TIMEOUT_SECONDS}
EOF
  fi

  if uses_slack; then
    cat <<EOF
slack:
  bot_token: "${SLACK_BOT_TOKEN}"
  app_token: "${SLACK_APP_TOKEN}"
  allowed_user_ids:
$(render_list_yaml "${SLACK_ALLOWED_USER_IDS}" "    ")
  notification_channel_ids:
$(render_list_yaml "${SLACK_CHANNEL_IDS}" "    ")
  command_name: "${SLACK_COMMAND_NAME}"
EOF
  fi

  cat <<EOF
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
Description=Infra Bot messaging service
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
  if [[ "${UPDATE_MODE}" -eq 1 ]]; then
    log "Restarting services"
  fi
  systemctl daemon-reload
  systemctl enable infra-bot.service >/dev/null
  systemctl enable infra-bot-update.timer >/dev/null
  systemctl restart infra-bot.service
  systemctl restart infra-bot-update.timer
}

verify_install() {
  local service_state timer_state revision
  service_state="$(systemctl is-active infra-bot.service 2>/dev/null || true)"
  timer_state="$(systemctl is-enabled infra-bot-update.timer 2>/dev/null || true)"
  revision="$(source_revision)"

  [[ "${service_state}" == "active" ]] || die "infra-bot.service is not active (state: ${service_state:-unknown})."
  systemctl is-enabled infra-bot-update.timer >/dev/null || die "infra-bot-update.timer is not enabled."
  [[ -x "${UPDATE_COMMAND_PATH}" ]] || die "Missing update helper at ${UPDATE_COMMAND_PATH}"

  if [[ "${UPDATE_MODE}" -eq 1 ]]; then
    log "Update complete"
    printf '  ref:      %s\n' "${DEFAULT_REPO_REF}"
    if [[ -n "${revision}" ]]; then
      printf '  revision: %s\n' "${revision}"
    fi
    printf '  service:  %s\n' "${service_state}"
    printf '  timer:    %s\n' "${timer_state}"
    printf '  config:   %s (unchanged)\n' "${CONFIG_PATH}"
    return
  fi

  log "Installation complete."
  printf '\nFollow-up commands:\n'
  printf '  systemctl status infra-bot.service\n'
  printf '  systemctl list-timers infra-bot-update.timer\n'
  printf '  %s --config %s status\n' "${VENV_DIR}/bin/infra-bot" "${CONFIG_PATH}"
  printf '  sudo infra-bot-update\n'
  printf '\nNote: ~/infra-bot is optional after install. Day-2 updates use:\n'
  printf '  sudo infra-bot-update\n'
}

main() {
  parse_args "$@"
  require_root
  validate_repo
  check_os
  ensure_base_commands
  install_prereqs
  detect_repo_metadata

  if [[ "${UPDATE_MODE}" -eq 1 ]]; then
    load_runtime_settings_from_config
    log "Updating infra-bot (config preserved)"
  else
    collect_inputs
    validate_required_inputs
    confirm_summary
  fi

  create_user_and_dirs
  sync_source_tree
  install_python_package
  if [[ "${KEEP_CONFIG}" -eq 0 ]]; then
    write_config
  fi
  write_install_conf
  install_update_helper
  write_service_units
  activate_services
  verify_install
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
