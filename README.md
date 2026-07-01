# NemoClaw on Jetson Thor

Install NemoClaw on a native NVIDIA Jetson AGX Thor Developer Kit, use local Ollama inference, and connect a sandbox to Telegram.

This guide uses:

```text
Ollama model: qwen3.6:35b
Sandbox name: my-assistant3
```

## 1. Install Ollama

Verify the device:

```bash
uname -m
cat /etc/os-release
```

Expected shape:

```text
aarch64
Ubuntu 24.04.x LTS
```

Install prerequisites and Ollama:

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
systemctl is-active ollama
curl -fsS http://127.0.0.1:11434/api/tags | jq .
```

On the reference Thor device:

```text
/usr/local/bin/ollama
ollama version is 0.30.7
active
```

## 2. Download or Verify the Local Model

This guide uses `qwen3.6:35b`:

```bash
export OLLAMA_MODEL=qwen3.6:35b
ollama pull "$OLLAMA_MODEL"
ollama list | grep "$OLLAMA_MODEL"
```

Quick test:

```bash
ollama run "$OLLAMA_MODEL"
```

At the prompt:

```text
Say hello from Jetson Thor in one sentence.
/bye
```

HTTP API test:

```bash
curl -s http://127.0.0.1:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"${OLLAMA_MODEL}\",
    \"prompt\": \"Say hello from Jetson Thor in one sentence.\",
    \"stream\": false
  }" | jq .
```

For the smaller model used in earlier tests, replace `qwen3.6:35b` with `qwen3.6:25b`.

## 3. Create a Telegram Bot

In Telegram, open the official BotFather:

```text
@BotFather
```

Create a bot:

```text
/newbot
```

BotFather returns a token like:

```text
1234567890:AAExampleTokenString_DoNotCommitRealTokens
```

Set the token only in your shell:

```bash
export TELEGRAM_BOT_TOKEN='PASTE_YOUR_BOT_TOKEN_HERE'
```

Verify the token and save the bot ID:

```bash
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | jq .
export TELEGRAM_BOT_ID="$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | jq -r '.result.id')"
echo "$TELEGRAM_BOT_ID"
```

Use a dedicated bot token for this NemoClaw sandbox. Reusing one token in multiple bot services can cause:

```text
Conflict: terminated by other getUpdates request; make sure that only one bot instance is running
```

## 4. Install and Configure NemoClaw

Set the sandbox name:

```bash
export NEMOCLAW_SANDBOX_NAME=my-assistant3
```

Install NemoClaw:

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  bash -s -- --yes-i-accept-third-party-software
```

From this repository checkout, the local bootstrap script is also available:

```bash
./install_nemoclaw.sh --yes-i-accept-third-party-software
```

Run onboarding:

```bash
nemoclaw onboard
```

Choose:

```text
Provider: local Ollama / ollama-local
Model: qwen3.6:35b
Sandbox name: my-assistant3
```

For an existing install, set the inference route directly:

```bash
nemoclaw inference set \
  --provider ollama-local \
  --model qwen3.6:35b \
  --sandbox "$NEMOCLAW_SANDBOX_NAME"
```

Verify:

```bash
nemoclaw inference get --json
nemoclaw "$NEMOCLAW_SANDBOX_NAME" status
nemoclaw "$NEMOCLAW_SANDBOX_NAME" doctor --json
```

Expected inference route:

```json
{
  "provider": "ollama-local",
  "model": "qwen3.6:35b"
}
```

## 5. Apply Basic Network Policies

The bundled policy files are required for a useful base setup:

- `openclaw-local-gateway.yaml`: allows OpenClaw and Node inside the sandbox to reach the local OpenClaw gateway WebSocket.
- `weather-apis.yaml`: allows weather tools to call `wttr.in`, Open-Meteo, and `weather.gov`.

Preview and apply:

```bash
ls -l nemoclaw_thor/policies/

nemoclaw "$NEMOCLAW_SANDBOX_NAME" policy-add \
  --from-dir ./nemoclaw_thor/policies \
  --dry-run

nemoclaw "$NEMOCLAW_SANDBOX_NAME" policy-add \
  --from-dir ./nemoclaw_thor/policies \
  --yes

nemoclaw "$NEMOCLAW_SANDBOX_NAME" policy-list
```

If you need to patch the gateway policy on another Thor device, edit the `host:` entries before applying:

```bash
sed -n '1,120p' nemoclaw_thor/policies/openclaw-local-gateway.yaml
nemoclaw "$NEMOCLAW_SANDBOX_NAME" doctor --json | jq .
nemoclaw "$NEMOCLAW_SANDBOX_NAME" logs --tail 200 | grep -Ei 'gateway|18790|websocket'
```

Keep port `18790` unless your gateway logs show a different port.

## 6. Connect Telegram

Enable the Telegram channel:

```bash
nemoclaw "$NEMOCLAW_SANDBOX_NAME" channels list
nemoclaw "$NEMOCLAW_SANDBOX_NAME" channels add telegram
```

When prompted:

- Use `TELEGRAM_BOT_TOKEN` for the bot token.
- Use `TELEGRAM_BOT_ID` only if the flow asks for the bot ID.
- Use your Telegram user, group, or channel ID if the flow asks for an allowed sender or destination ID.

For a Telegram channel or group, add the bot and make it an admin if NemoClaw needs to post messages.

Verify:

```bash
nemoclaw "$NEMOCLAW_SANDBOX_NAME" channels list
nemoclaw "$NEMOCLAW_SANDBOX_NAME" status
nemoclaw "$NEMOCLAW_SANDBOX_NAME" logs --tail 120
nemoclaw "$NEMOCLAW_SANDBOX_NAME" dashboard-url
```

Send a test message to the Telegram bot from the allowed Telegram account or channel. A healthy setup routes the message into NemoClaw/OpenClaw, uses local Ollama `qwen3.6:35b`, and replies through Telegram.

## Troubleshooting

Ollama:

```bash
sudo systemctl status ollama --no-pager
journalctl -u ollama -n 100 --no-pager
ollama list
ollama ps
```

NemoClaw:

```bash
nemoclaw inference get --json
nemoclaw "$NEMOCLAW_SANDBOX_NAME" doctor --json
nemoclaw "$NEMOCLAW_SANDBOX_NAME" logs --tail 200
```

Telegram:

- `Conflict: terminated by other getUpdates request` means another service is polling the same bot token.
- If Telegram cannot connect, confirm the sandbox has outbound access to `api.telegram.org`.
- If channel posting fails, confirm the bot is a member or admin of the target Telegram channel or group.

References:

- Ollama Linux install: https://docs.ollama.com/linux
- Telegram BotFather: https://telegram.me/BotFather
- Telegram bot tutorial: https://core.telegram.org/bots/tutorial
- NemoClaw: https://www.nvidia.com/nemoclaw
