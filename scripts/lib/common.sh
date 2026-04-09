#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[infra-bot] %s\n' "$*"
}

warn() {
  printf '[infra-bot] warning: %s\n' "$*" >&2
}

die() {
  printf '[infra-bot] error: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

prompt_with_default() {
  local prompt="$1"
  local default_value="${2:-}"
  local input=""
  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " input
    printf '%s\n' "${input:-$default_value}"
    return
  fi
  read -r -p "$prompt: " input
  printf '%s\n' "$input"
}

prompt_secret() {
  local prompt="$1"
  local default_value="${2:-}"
  local input=""
  if [[ -n "$default_value" ]]; then
    read -r -s -p "$prompt [leave blank to keep current]: " input
    printf '\n' >&2
    printf '%s\n' "${input:-$default_value}"
    return
  fi
  read -r -s -p "$prompt: " input
  printf '\n' >&2
  printf '%s\n' "$input"
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-Y}"
  local suffix="[Y/n]"
  local answer=""
  local normalized_default=""

  normalized_default="$(printf '%s' "${default_answer}" | tr '[:lower:]' '[:upper:]')"

  if [[ "${normalized_default}" == "N" ]]; then
    suffix="[y/N]"
  fi

  read -r -p "$prompt $suffix: " answer
  answer="${answer:-$default_answer}"
  case "$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')" in
    y|yes) return 0 ;;
    n|no) return 1 ;;
    *) warn "Please answer yes or no."; prompt_yes_no "$prompt" "$default_answer"; return $? ;;
  esac
}

mask_secret() {
  local value="$1"
  local length="${#value}"
  if (( length <= 4 )); then
    printf '****\n'
    return
  fi
  printf '%s****%s\n' "${value:0:2}" "${value:length-2:2}"
}

trim_spaces() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}
