#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  apply-hermes.sh [SANDBOX_NAME]

Environment:
  NEMOCLAW_SANDBOX_NAME  Sandbox name if no argument is provided.
  OLLAMA_MODEL           Model for the proxy smoke check. Default: qwen3.6:35b.
  RUN_AGENT_SMOKE=1      Also run the slow end-to-end weather agent prompt.
  SKIP_PROXY_PATCH=1     Do not replace/restart the Ollama auth proxy.

Example:
  ./nemoclaw_thor/fix-weather-tools/apply-hermes.sh hermes
USAGE
}

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '\nWARN: %s\n' "$*" >&2
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

sandbox_exec_script() {
  local interpreter="$1"
  local script="$2"
  local encoded

  # OpenShell rejects exec arguments containing literal newlines. Encode the
  # script into one line, then restore it to a temporary file in the sandbox.
  encoded="$(node -e 'process.stdout.write(Buffer.from(process.argv[1], "utf8").toString("base64"))' "$script")"
  nemoclaw "$SANDBOX_NAME" exec -- sh -c \
    'tmp="$(mktemp)" || exit 1; printf %s "$1" | base64 -d > "$tmp" || { rc=$?; rm -f "$tmp"; exit "$rc"; }; "$2" "$tmp"; rc=$?; rm -f "$tmp"; exit "$rc"' \
    nemoclaw-script "$encoded" "$interpreter"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SANDBOX_NAME="${1:-${NEMOCLAW_SANDBOX_NAME:-}}"
[[ -n "$SANDBOX_NAME" ]] || die "provide a Hermes sandbox name, for example: apply-hermes.sh hermes"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.6:35b}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
POLICY_DIR="${REPO_ROOT}/nemoclaw_thor/policies"
SKILL_DIR="${SCRIPT_DIR}/nemoclaw_weather_open_meteo_skill"
PROXY_SRC="${SCRIPT_DIR}/ollama-auth-proxy.fixed.js"
PROXY_DST="${HOME}/.nemoclaw/source/scripts/ollama-auth-proxy.js"
PROXY_TOKEN_FILE="${HOME}/.nemoclaw/ollama-proxy-token"
PROXY_PID_FILE="${HOME}/.nemoclaw/ollama-auth-proxy.pid"
PROXY_LOG="/tmp/nemoclaw-ollama-auth-proxy.log"

need_cmd nemoclaw
need_cmd openshell
need_cmd curl
need_cmd node
need_cmd setsid

[[ -d "$POLICY_DIR" ]] || die "policy directory not found: $POLICY_DIR"
[[ -d "$SKILL_DIR" ]] || die "weather skill directory not found: $SKILL_DIR"

log "Using sandbox: ${SANDBOX_NAME}"
nemoclaw "$SANDBOX_NAME" status >/dev/null
nemoclaw "$SANDBOX_NAME" exec -- sh -c \
  'test -f /sandbox/.hermes/config.yaml && command -v hermes >/dev/null' \
  || die "sandbox '${SANDBOX_NAME}' is not a configured Hermes sandbox"

log "Applying NemoClaw network policies"
nemoclaw "$SANDBOX_NAME" policy-add --from-dir "$POLICY_DIR" --yes
nemoclaw "$SANDBOX_NAME" policy-add weather --yes || warn "built-in weather policy could not be enabled; continuing with bundled policy files"

log "Installing Open-Meteo weather skill for Hermes"
nemoclaw "$SANDBOX_NAME" skill install "$SKILL_DIR"

log "Restarting Hermes gateway and restoring dashboard forwarding"
nemoclaw "$SANDBOX_NAME" recover

dashboard_url="$(nemoclaw "$SANDBOX_NAME" dashboard-url --quiet)"
dashboard_port="$(node -e 'process.stdout.write(new URL(process.argv[1]).port)' "$dashboard_url")"
[[ -n "$dashboard_port" ]] || die "could not determine Hermes dashboard port from dashboard-url"

if ! curl -fsS --max-time 10 "$dashboard_url" >/dev/null; then
  warn "dashboard forward is not reachable; recreating port ${dashboard_port}"
  forward_log="/tmp/nemoclaw-${SANDBOX_NAME}-dashboard-forward.log"
  setsid -f openshell forward start --background "$dashboard_port" "$SANDBOX_NAME" \
    </dev/null >"$forward_log" 2>&1

  dashboard_ready=0
  for _ in {1..10}; do
    sleep 1
    if curl -fsS --max-time 5 "$dashboard_url" >/dev/null; then
      dashboard_ready=1
      break
    fi
  done
  if [[ "$dashboard_ready" != "1" ]]; then
    tail -n 40 "$forward_log" >&2 || true
    die "failed to recreate Hermes dashboard forward on port ${dashboard_port}"
  fi
fi
curl -fsS --max-time 10 "$dashboard_url" >/dev/null \
  || die "Hermes dashboard is not reachable at ${dashboard_url}"

if [[ "${SKIP_PROXY_PATCH:-0}" != "1" ]]; then
  log "Installing fixed Ollama auth proxy"
  [[ -f "$PROXY_SRC" ]] || die "fixed proxy source not found: $PROXY_SRC"
  [[ -d "$(dirname "$PROXY_DST")" ]] || die "NemoClaw source scripts directory not found: $(dirname "$PROXY_DST")"
  if [[ -f "$PROXY_DST" ]]; then
    backup="${PROXY_DST}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$PROXY_DST" "$backup"
    printf 'Backed up existing proxy to %s\n' "$backup"
  fi
  cp "$PROXY_SRC" "$PROXY_DST"
  chmod 755 "$PROXY_DST"

  log "Restarting Ollama auth proxy"
  old_pid="$(cat "$PROXY_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]]; then
    kill "$old_pid" 2>/dev/null || true
  fi
  [[ -f "$PROXY_TOKEN_FILE" ]] || die "proxy token file not found: $PROXY_TOKEN_FILE"
  OLLAMA_PROXY_TOKEN="$(cat "$PROXY_TOKEN_FILE")" \
    setsid node "$PROXY_DST" >"$PROXY_LOG" 2>&1 < /dev/null &
  proxy_pid="$!"
  echo "$proxy_pid" > "$PROXY_PID_FILE"
  sleep 1
  kill -0 "$proxy_pid" 2>/dev/null || {
    tail -n 80 "$PROXY_LOG" >&2 || true
    die "Ollama auth proxy failed to start"
  }

  log "Checking Ollama auth proxy tool-result path"
  token="$(cat "$PROXY_TOKEN_FILE")"
  proxy_result="$(
    curl -sS --max-time 60 http://127.0.0.1:11435/v1/chat/completions \
      -H "Authorization: Bearer ${token}" \
      -H 'Content-Type: application/json' \
      -d "{
        \"model\": \"${OLLAMA_MODEL}\",
        \"messages\": [
          {\"role\": \"user\", \"content\": \"Use this tool result and reply exactly final-ok\"},
          {
            \"role\": \"assistant\",
            \"content\": \"\",
            \"tool_calls\": [
              {
                \"id\": \"call_1\",
                \"type\": \"function\",
                \"function\": {
                  \"name\": \"exec\",
                  \"arguments\": \"{\\\"command\\\":\\\"echo hi\\\"}\"
                }
              }
            ]
          },
          {\"role\": \"tool\", \"tool_call_id\": \"call_1\", \"name\": \"exec\", \"content\": \"hi\"}
        ],
        \"stream\": true
      }"
  )"
  printf '%s\n' "$proxy_result" | grep -q 'final-ok' \
    || warn "proxy smoke did not include final-ok"
else
  warn "SKIP_PROXY_PATCH=1 set; leaving Ollama auth proxy unchanged"
fi

log "Checking Open-Meteo access inside sandbox"
open_meteo_check_script='
set -eu
curl -fsS "https://geocoding-api.open-meteo.com/v1/search?name=Taipei&count=1&language=en&format=json" >/dev/null
curl -fsS "https://api.open-meteo.com/v1/forecast?latitude=25.05306&longitude=121.52639&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m&timezone=Asia%2FTaipei" >/dev/null
'
sandbox_exec_script /usr/bin/sh "$open_meteo_check_script"

log "Checking Hermes weather skill is installed"
nemoclaw "$SANDBOX_NAME" exec -- hermes skills list | grep -i weather \
  || warn "weather skill was not visible in hermes skills list"

if [[ "${RUN_AGENT_SMOKE:-0}" == "1" ]]; then
  log "Running end-to-end Hermes weather agent smoke"
  nemoclaw "$SANDBOX_NAME" exec --timeout 240 -- \
    hermes --oneshot "please get me the current weather of Taipei City"
else
  log "Skipping slow agent smoke; set RUN_AGENT_SMOKE=1 to run it"
fi

log "Done"
