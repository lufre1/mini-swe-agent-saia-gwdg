# mini-swe-agent-saia-gwdg

GWDG SAIA provider for **mini-swe-agent**

This repo provides an installer that configures [mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent) to use the [GWDG SAIA](https://chat-ai.academiccloud.de/) OpenAI-compatible API, giving you access to 14 ready models including Qwen, DeepSeek, GLM, and more.

## Quick start

```bash
SAIA_API_KEY="your-key" bash install-mini-swe-agent-saia-gwdg.sh --yes
```

No key in the environment? Run `bash install-mini-swe-agent-saia-gwdg.sh --yes` and it asks for one
(or pass `--key <value>` / `--key-file <path>`). Reinstalls reuse the key already in
your shell rc, so you only ever type it once.

This one-shot installer:
- Installs mini-swe-agent (if missing) via `pip install mini-swe-agent`
- Writes `~/.config/mini-swe-agent/.env` making SAIA the default model, so mini runs with **no OpenAI account**
- Writes `~/.config/mini-swe-agent/mini.yaml`: mini's builtin config with the model pointed at the GWDG SAIA endpoint
- Writes `~/.config/mini-swe-agent/model_registry.json` registering the 14 ready models for cost tracking
- Persists the key as `SAIA_API_KEY` in your shell rc (mini's `.env` maps it to `OPENAI_API_KEY=${SAIA_API_KEY}` for litellm)
- Optional, with `--keyring`: routes mini through a local
  key-rotating proxy that swaps keys automatically when one is revoked, drained or
  rate limited (see `SETUP.md` → *Multiple keys*)
- Works on macOS, Linux, and WSL

Or see `SETUP.md` for detailed instructions and troubleshooting.

## What's included

| File | Purpose |
|------|---------|
| `install-mini-swe-agent-saia-gwdg.sh` | Self-contained installer (generated; never edit directly) |
| `build.sh` | Regenerates the installer from source files |
| `src/add-saia-mini-swe-agent.sh` | Live source script (portable key sourcing + config write) |
| `src/models.txt` | List of 14 ready SAIA models |
| `src/mini.yaml.tmpl` | mini-swe-agent agent config template (model_kwargs) |
| `src/model_registry.json.tmpl` | litellm model registry template (cost tracking) |
| `src/saia_keyring.py`, `src/saia-keyring.sh` | Key-rotating proxy and its install logic, vendored from `opencode-extras/keyring/` (never edit here) |
| `test/fake-saia.py` | Fake SAIA endpoint for the smoke test (not packed) |
| `test/test-install.sh` | Smoke test that verifies the config is written (not packed) |

## Architecture

```
SAIA_API_KEY → install-mini-swe-agent-saia-gwdg.sh → [pip install mini-swe-agent]
                                                          │
                                                          ▼
                                          src/add-saia-mini-swe-agent.sh
                                                          │
                    ┌─────────────────────────────────────┼──────────────────────────────┐
                    ▼                                     ▼                              ▼
        ~/.config/mini-swe-agent/.env      ~/.config/mini-swe-agent/mini.yaml   model_registry.json
        (MSWEA_MODEL_NAME, paths)          (model_kwargs → SAIA endpoint)       (litellm cost registry)
                                                                                          │
                                                                                          ▼
                                                              https://chat-ai.academiccloud.de/v1
```

## Maintaining

After changing `src/add-saia-mini-swe-agent.sh`, `src/models.txt`, `src/mini.yaml.tmpl` or `src/model_registry.json.tmpl`, regenerate the installer
(the keyring files are synced in by `opencode-extras/keyring/sync.sh`, which also rebuilds):

```bash
./build.sh
```

## License

MIT
