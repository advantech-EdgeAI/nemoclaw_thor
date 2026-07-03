# NemoClaw OpenClaw Weather Fix Package

Host-side fix package for a fresh NemoClaw + Ollama + OpenClaw setup where:

- OpenClaw exposes `tool_search_code` and the model fails while editing files or using tools.
- Weather prompts return "network access is blocked" because the bundled weather skill uses `wttr.in`.
- Ollama tool-result follow-up turns hang or time out through the local auth proxy.

## Quick Apply

From the repository root:

```bash
./nemoclaw_thor/fix-weather-tools/apply.sh my-assistant3
```

Or use the environment variable:

```bash
export NEMOCLAW_SANDBOX_NAME=my-assistant3
./nemoclaw_thor/fix-weather-tools/apply.sh
```

The script runs on the host. It will:

- apply the bundled NemoClaw policies;
- enable the built-in `weather` policy;
- configure OpenClaw to use structured `tool_search`, `tool_describe`, and `tool_call`;
- restart the OpenShell sandbox container;
- install the Open-Meteo weather skill override;
- install a fixed Ollama auth proxy and restart it;
- run lightweight proxy and Open-Meteo smoke checks.

Set `OLLAMA_MODEL` if your local model is not `qwen3.6:35b`:

```bash
OLLAMA_MODEL=qwen3.6:25b ./nemoclaw_thor/fix-weather-tools/apply.sh my-assistant3
```

## Optional End-to-End Smoke

The full agent test can take a while on local models, so it is opt-in:

```bash
RUN_AGENT_SMOKE=1 ./nemoclaw_thor/fix-weather-tools/apply.sh my-assistant3
```

Expected prompt result: the assistant fetches live Taipei weather from Open-Meteo
and does not claim that network access is blocked.

## Files

- `apply.sh`: host-side installer.
- `ollama-auth-proxy.fixed.js`: replacement local Ollama auth proxy with native
  `/api/chat` translation for `/v1/chat/completions`.
- `nemoclaw_weather_open_meteo_skill/SKILL.md`: OpenClaw weather skill override
  that instructs the assistant to use Open-Meteo.
