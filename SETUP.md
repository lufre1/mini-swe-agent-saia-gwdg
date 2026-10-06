# GWDG SAIA Provider Setup for mini-swe-agent

## Summary

This installer configures the GWDG SAIA provider in mini-swe-agent with 14 ready models.

## Prerequisites

- **SAIA API key** (from GWDG SAIA) — the installer reuses the key from a previous
  install, and prompts for it only when there is none
- **Python 3 + pip** — mini-swe-agent will be installed automatically if missing
  (via `pip install mini-swe-agent`)

## Quick start

```bash
SAIA_API_KEY="your-key" bash install-mini-swe-agent-saia-gwdg.sh --yes
```

This one-shot installer:
- Installs mini-swe-agent (if missing) via pip
- Writes `~/.config/mini-swe-agent/.env`, `mini.yaml` and `model_registry.json`
- Works on macOS, Linux, and WSL

## Detailed installation

### 1. Obtain your SAIA API key

Your key is stored in `~/.local/share/opencode/auth.json` (if you use opencode with SAIA), or you can generate a new one at the GWDG SAIA portal.

### 2. Run the installer

```bash
# Option A: via environment variable (recommended)
SAIA_API_KEY="your-key" bash install-mini-swe-agent-saia-gwdg.sh --yes

# Option B: via --key argument
bash install-mini-swe-agent-saia-gwdg.sh --key "your-key" --yes

# Option C: via --key-file (reads from a file)
bash install-mini-swe-agent-saia-gwdg.sh --key-file ~/.local/share/opencode/auth.json --yes

# Option D: pass nothing — reuses the key from a previous install,
# or asks for it (input hidden) if this is the first one
bash install-mini-swe-agent-saia-gwdg.sh --yes
```

The `--yes` flag enables non-interactive mode and auto-installs mini-swe-agent if missing. Without it, the installer will prompt before installing.

The installer will:
- Verify mini-swe-agent is installed (or install it)
- Back up your existing config files if they already exist
- Write the SAIA provider config
- Verify the config was written

### 3. Verify installation

```bash
cat ~/.config/mini-swe-agent/.env
cat ~/.config/mini-swe-agent/mini.yaml
```

You should see `MSWEA_MODEL_NAME` and a `mini.yaml` pointing at `https://chat-ai.academiccloud.de/v1`.

### 4. Test the provider

```bash
mini -t "Say hello"
```

## Usage

### Start a session with a SAIA model

```bash
# Use the default model (deepseek-v4-flash-0731)
mini

# Or start with a specific model
mini -m qwen3-coder-next
```

### Available models

All 14 ready SAIA models:

- apertus-70b-instruct-2509
- devstral-2-123b-instruct-2512
- qwen3.8-27b
- deepseek-v4-flash-0731
- glm-5.3-flash
- qwen3-coder-next
- qwen3-omni-30b-a3b-instruct
- mistral-medium-3.5-128b
- qwen3.5-397b-a17b
- gemma-4-31b-it
- qwen3.6-35b-a3b
- meta-llama-3.1-8b-instruct
- openai-gpt-oss-120b
- qwen3-30b-a3b-instruct-2507

## Config schema

The provider is stored in `~/.config/mini-swe-agent/`:

`mini.yaml` is a **full** config: `MSWEA_MINI_CONFIG_PATH` replaces mini's builtin
`mini.yaml` instead of merging with it, so the installer merges `src/mini.yaml.tmpl`
onto the builtin one (agent templates included). The SAIA part:

```yaml
model:
  model_name: deepseek-v4-flash-0731
  model_kwargs:
    drop_params: true
    custom_llm_provider: openai
    api_base: https://chat-ai.academiccloud.de/v1
  cost_tracking: ignore_errors
```

Re-run the installer after upgrading mini-swe-agent, so the builtin templates stay current.

`.env`:

```
MSWEA_MODEL_NAME=deepseek-v4-flash-0731
OPENAI_API_KEY=${SAIA_API_KEY}
MSWEA_MINI_CONFIG_PATH=/home/<user>/.config/mini-swe-agent/mini.yaml
LITELLM_MODEL_REGISTRY_PATH=/home/<user>/.config/mini-swe-agent/model_registry.json
MSWEA_COST_TRACKING=ignore_errors
MSWEA_GLOBAL_CONFIG_DIR=/home/<user>/.config/mini-swe-agent
MSWEA_CONFIGURED=true
```

**Note**: mini does not expand env vars in `mini.yaml`, so the key is not there. It is persisted to your shell rc as `SAIA_API_KEY`, and `.env` (loaded by mini through python-dotenv, which does expand `${...}`) maps it to `OPENAI_API_KEY`, the variable litellm reads. An `OPENAI_API_KEY` you already export takes precedence; unset it when running mini. The config files have 600 permissions (owner read/write only).

## Multiple keys: automatic key swap

SAIA rate limits are per key (30/min, 200/hour, 1000/day, 3000/month). Opt in with
`--keyring`, give the installer extra keys, and mini-swe-agent swaps to the next one by
itself when the active key is revoked (401/403), drained (its hour/day/month budget
nearly used up) or rate limited (429) — the same rotation the opencode setup does.

```bash
# Extra keys via the environment, so they never show up in `ps`
SAIA_API_KEYS_EXTRA="key2,key3" bash install-mini-swe-agent-saia-gwdg.sh --yes --keyring

# Or reuse the extra keys of an opencode setup
bash install-mini-swe-agent-saia-gwdg.sh --yes --keyring --extra-keys-file ~/.local/share/opencode/saia-gwdg-keys.json
```

With `--keyring` the installer starts **saia-keyring**, a small local proxy
(`~/.local/share/saia-keyring/saia_keyring.py`, stdlib Python 3), and points
`model_kwargs.api_base` in `~/.config/mini-swe-agent/mini.yaml` at
`http://127.0.0.1:8788/v1` instead of SAIA. mini keeps sending its usual key
(`OPENAI_API_KEY=${SAIA_API_KEY}`); the proxy only serves requests carrying one of the
configured keys and forwards them on the active key. Every harness installed with extra
keys shares the same proxy and key list. Keys are only swapped before a response
starts — a response in progress is never cut over.

| What | Where |
|------|-------|
| Keys | `~/.config/saia-keyring/keyring.json` (chmod 600), primary key first. A reinstall without extra keys keeps the stored ones; a changed list is backed up to `keyring.json.bak-<timestamp>` |
| Status | `saia-keyring status` — per-key budget, the active key, rejected keys |
| Log | `~/.cache/saia-keyring/proxy.log` |
| Service | systemd user unit `saia-keyring` (Linux), launchd agent `de.gwdg.saia-keyring` (macOS), otherwise a line in your shell rc |
| Turn off | re-run without `--keyring`: mini talks to SAIA directly again |

Without `--keyring` none of this is installed: mini talks to SAIA directly with one key,
as before (extra keys are then ignored). When every key is out, mini shows why — e.g.
`All 3 SAIA key(s) rejected by SAIA (...) — the key(s) are revoked or expired` (mini
does not retry a 401, so it stops right away).

## Troubleshooting

### Config not taking effect

```bash
cat ~/.config/mini-swe-agent/.env
cat ~/.config/mini-swe-agent/mini.yaml
```

### API key errors

- Ensure `SAIA_API_KEY` is set correctly (no quotes in the env var value); with no
  key set at all, the installer asks for one, and fails only if there is no terminal
  to ask on (CI, cron) — set the env var there
- Verify the key is valid at the GWDG SAIA portal
- Check rate limits: 30 req/min, 200/hour, 1000/day, 3000/month per key

### mini-swe-agent not found

The installer automatically installs mini-swe-agent via pip if missing:

```bash
pip install mini-swe-agent
```

If `mini` is still not on your PATH after install, add the pip bin dir to your PATH or use `python3 -m pip install --user mini-swe-agent`.

## Advanced: Regenerate the installer

If you modify `src/add-saia-mini-swe-agent.sh`, `src/models.txt`, `src/mini.yaml.tmpl` or `src/model_registry.json.tmpl`, regenerate the installer.
`src/saia_keyring.py` and `src/saia-keyring.sh` are vendored from
`opencode-saia-gwdg/keyring/` — change them there and run its `keyring/sync.sh`.

```bash
./build.sh
```

This creates a new `install-mini-swe-agent-saia-gwdg.sh` with the changes embedded.

## License

MIT
