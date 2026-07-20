#!/usr/bin/env bash
set -Eeuo pipefail

patch_nemoclaw_curl_pin() {
  local dockerfile="/home/test/.nemoclaw/source/agents/hermes/Dockerfile.base"
  local old_pin="curl=8.14.1-2+deb13u3"
  local new_pin="curl=8.14.1-2+deb13u4"

  [[ -f "$dockerfile" ]] || {
    printf 'ERROR: Hermes Dockerfile not found: %s\n' "$dockerfile" >&2
    return 1
  }

  if grep -Fq "$new_pin" "$dockerfile"; then
    printf 'Hermes curl package pin is already patched: %s\n' "$new_pin"
    return 0
  fi

  if grep -Fq "$old_pin" "$dockerfile"; then
    sed -i 's|curl=8\.14\.1-2+deb13u3|curl=8.14.1-2+deb13u4|' "$dockerfile"
    grep -Fq "$new_pin" "$dockerfile" || {
      printf 'ERROR: failed to patch curl package pin in %s\n' "$dockerfile" >&2
      return 1
    }
    printf 'Patched Hermes curl package pin: %s -> %s\n' "$old_pin" "$new_pin"
    return 0
  fi

  printf 'WARN: expected curl pin was not found in %s; leaving it unchanged\n' "$dockerfile" >&2
  grep -E '^[[:space:]]*curl=' "$dockerfile" >&2 || true
}

patch_nemoclaw_curl_pin

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  if [[ -t 0 ]]; then
    read -rsp "Telegram bot token: " TELEGRAM_BOT_TOKEN
    printf '\n'
  else
    printf 'ERROR: set TELEGRAM_BOT_TOKEN before running this script\n' >&2
    exit 1
  fi
fi

export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
export TELEGRAM_ALLOWED_IDS="${TELEGRAM_ALLOWED_IDS}"
export TELEGRAM_REQUIRE_MENTION="${TELEGRAM_REQUIRE_MENTION:-1}"
export NEMOCLAW_NON_INTERACTIVE=1

nemoclaw hermes channels add telegram
