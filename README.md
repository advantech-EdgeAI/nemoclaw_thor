# NemoClaw on Jetson Thor

Install NemoClaw on a native NVIDIA Jetson AGX Thor Developer Kit, use local Ollama inference, and connect a sandbox to Telegram.

## 1. Install prerequisites and Ollama

```bash
sudo apt update
sudo apt install -y curl ca-certificates jq
curl -fsSL https://ollama.com/install.sh | sh
```

Start and verify the service:

```bash
sudo systemctl enable --now ollama
command -v ollama
ollama --version
```

## 2. Download, Run and Verify the Local Model

Download and Run. This guide uses `qwen3.6:35b`:

```bash
export OLLAMA_MODEL=qwen3.6:35b
ollama run "$OLLAMA_MODEL"
```

At the prompt:

```text
Say hello from Jetson Thor in one sentence.
/bye
```

Quick test: Query Modles
```bash
curl -fsS http://127.0.0.1:11434/api/tags | jq .
```


HTTP API test: Chat Testing

```bash
curl -s http://127.0.0.1:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"${OLLAMA_MODEL}\",
    \"prompt\": \"Say hello from Jetson Thor in one sentence.\",
    \"stream\": false
  }" | jq .
```

## 3. Create a Telegram Bot to get Bot Token and User ID, for pairing later at Step 4.

### In Telegram, Search and Open the official BotFather:

```text
@BotFather
```

Create a bot

```text
/newbot
```

BotFather returns a token like:

```text
1234567890:AAExampleTokenString_DoNotCommitRealTokens
```

Then Set the token in your shell:

```bash
export TELEGRAM_BOT_TOKEN='PASTE_YOUR_BOT_TOKEN_HERE'
```

### In Telegram, Search and Open the official UserInfo:

```text
@userinfobot
```

Send start to bot to get your ID

```text
/start
```

Then Set the User ID in your shell:

```bash
export TELEGRAM_USER_ID='PASTE_YOUR_HUMAN_TELEGRAM_USER_ID_HERE'
```

## 4. Install and Configure NemoClaw

### Install NemoClaw:

From this repository checkout, the NemoClaw install script is available:

```bash
./install_nemoclaw.sh --yes-i-accept-third-party-software
```

### After installation done, run onboarding:

```bash
NEMOCLAW_RECREATE_WITHOUT_BACKUP=1 nemoclaw onboard

... [3/8]
Select your inference provider: 
7) Local Ollama ...

Ollama models:
17) Other...

Choose model [1]: 17
Ollama model id: qwen3.6:35b

... [4/8]
Sandbox name ... [hermes]:

... [5/8]
[1] * telegram - Telegram bot messaging
Telegram Bot Toekn: <Bot Token>
Telegram User ID (for DM access): <Your User ID>

----------------
Hermes is ready

Sandbox: hermes
Model: qwen3.6:35b (Local Ollama)

```

Verify:
```bash
nemoclaw "$NEMOCLAW_SANDBOX_NAME" status
```

Expected inference route:

```json
{
  "provider": "ollama-local",
  "model": "qwen3.6:35b"
}
```

## 5. Apply Basic Network Policies

```bash
export NEMOCLAW_SANDBOX_NAME=hermes
./nemoclaw_thor/fix-weather-tools/apply-hermes.sh "$NEMOCLAW_SANDBOX_NAME"
```

The script runs on the host. It will:

- apply the bundled NemoClaw policies;
- enable the built-in `weather` policy;
- configure Hermes Agent to use structured `tool_search`, `tool_describe`, and `tool_call`;
- restart the OpenShell sandbox container;
- install the Open-Meteo weather skill override;
- install a fixed Ollama auth proxy and restart it;
- run lightweight proxy and Open-Meteo smoke checks.

Set `OLLAMA_MODEL` if your local model is not `qwen3.6:35b`:

```bash
OLLAMA_MODEL=qwen3.6:25b ./nemoclaw_thor/fix-weather-tools/apply.sh "$NEMOCLAW_SANDBOX_NAME"
```

## 6. Connect Telegram
```bash
export TELEGRAM_BOT_TOKEN=<Bot Token>
export TELEGRAM_ALLOWED_IDS=<User ID>
./nemoclaw_thor/add-telegram-to-nemoclaw-hermes.sh
```

From your Telegram APP, send a test message to the Telegram bot from the allowed Telegram account or channel. A healthy setup routes the message into NemoClaw/Hermes Agent, uses local Ollama `qwen3.6:35b`, and replies through Telegram.


Verify from Host Terminal:

```bash
nemoclaw "$NEMOCLAW_SANDBOX_NAME" status
nemoclaw "$NEMOCLAW_SANDBOX_NAME" dashboard-url
```


## Troubleshooting

Telegram:

- `Conflict: terminated by other getUpdates request` means another service is polling the same bot token.
- `403: Forbidden: the bot can't send messages to the bot` means the target ID is the bot ID, not your human Telegram user ID.
- If Telegram cannot connect, confirm the sandbox has outbound access to `api.telegram.org`.
- If channel posting fails, confirm the bot is a member or admin of the target Telegram channel or group.
- If direct messages do not work, set `TELEGRAM_USER_ID` during `channels add telegram`
- If `channels add` or `channels remove` fails during rebuild with `NEMOCLAW_OLLAMA_PROXY_TOKEN` missing, export the saved local Ollama proxy token first:

```bash
nemoclaw "$NEMOCLAW_SANDBOX_NAME" channels remove telegram
nemoclaw "$NEMOCLAW_SANDBOX_NAME" channels add telegram
```

# NemoClaw Hermes Agent Weather Fix Package

Host-side fix package for a fresh NemoClaw + Ollama + Hermes Agent setup where:

- Hermes Agent exposes `tool_search_code` and the model fails while editing files or using tools.
- Weather prompts return "network access is blocked" because the bundled weather skill uses `wttr.in`.
- Ollama tool-result follow-up turns hang or time out through the local auth proxy.


## Optional End-to-End Smoke

The full agent test can take a while on local models, so it is opt-in:

```bash
RUN_AGENT_SMOKE=1 ./nemoclaw_thor/fix-weather-tools/apply.sh "$NEMOCLAW_SANDBOX_NAME"
```

Expected prompt result: the assistant fetches live Taipei weather from Open-Meteo and does not claim that network access is blocked.

## Files

- `ollama-auth-proxy.fixed.js`: replacement local Ollama auth proxy with native `/api/chat` translation for `/v1/chat/completions`.
- `nemoclaw_weather_open_meteo_skill/SKILL.md`: Hermes Agent weather skill override that instructs the assistant to use Open-Meteo.


References:

- Ollama Linux install: https://docs.ollama.com/linux
- Telegram BotFather: https://telegram.me/BotFather
- Telegram bot tutorial: https://core.telegram.org/bots/tutorial
- NemoClaw: https://www.nvidia.com/nemoclaw

