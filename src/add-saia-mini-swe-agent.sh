#!/usr/bin/env bash
set -euo pipefail

# Base URL override for tests and local gateways (default: production SAIA).
SAIA_BASE_URL="${SAIA_BASE_URL:-https://chat-ai.academiccloud.de/v1}"

# add-saia-mini-swe-agent.sh — Add GWDG SAIA provider to mini-swe-agent
#
# Reads SAIA API key from environment variable SAIA_API_KEY or --key/--key-file.
# Installs mini-swe-agent if missing (via pip), then writes the config that
# points mini-swe-agent (which uses litellm) at the GWDG SAIA OpenAI-compatible
# endpoint:
#
#   ~/.config/mini-swe-agent/.env            global config (dotenv)
#   ~/.config/mini-swe-agent/mini.yaml       custom agent config (model_kwargs)
#   ~/.config/mini-swe-agent/model_registry.json  litellm registry (cost tracking)
#
# The API key is referenced in .env as OPENAI_API_KEY=${SAIA_API_KEY} (dotenv
# interpolation) and persisted to the user's shell rc so mini-swe-agent can
# resolve it at runtime. The raw key is never written into the config files.
#
# Usage:
#   SAIA_API_KEY="your-key" ./add-saia-mini-swe-agent.sh
#   ./add-saia-mini-swe-agent.sh --key "your-key"
#   ./add-saia-mini-swe-agent.sh --key-file ~/.local/share/opencode/auth.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="${SCRIPT_DIR}/models.txt"
MINI_YAML_TMPL="${SCRIPT_DIR}/mini.yaml.tmpl"
REGISTRY_TMPL="${SCRIPT_DIR}/model_registry.json.tmpl"

# ── Parse arguments ──────────────────────────────────────────────────
ASSUME_YES=0
KEY=""
KEY_FILE=""
SAIA_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      KEY="$2"
      shift 2
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    --key-file)
      KEY_FILE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: SAIA_API_KEY=... ./add-saia-mini-swe-agent.sh [--key <key> | --key-file <path>]"
      echo ""
      echo "Options:"
      echo "  --key <value>       SAIA API key (overrides SAIA_API_KEY env)"
      echo "  --key-file <path>   File containing the SAIA API key"
      echo "  -y, --yes           Install the agent without asking (for non-TTY runs)"
      echo "  -h, --help          Show this help"
      echo ""
      echo "The API key is taken from:"
      echo "  1. --key <value> argument (if provided)"
      echo "  2. SAIA_API_KEY environment variable (if set)"
      echo "  3. --key-file <path> (reads first line)"
      echo "  4. the key stored by a previous install, if any"
      echo "  5. an interactive prompt, if none of the above is set"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Pull the key out of a previous install so a reinstall does not ask again.
# The key is persisted as `export SAIA_API_KEY=...` in the shell rc.
key_from_config() {
  local rc
  rc="$(detect_shell_rc)"
  [[ -n "$rc" && -f "$rc" ]] || return 0
  awk -F= '/^[[:space:]]*export[[:space:]]+SAIA_API_KEY=/{sub(/^[^=]*=/,""); gsub(/[\x27"]/,""); print; exit}' "$rc"
  return 0
}

detect_shell_rc() {
  if [[ -n "${SAIA_SHELL_RC:-}" ]]; then
    echo "$SAIA_SHELL_RC"
  elif [[ -n "${ZSH_VERSION:-}" && -f "$HOME/.zshrc" ]]; then
    echo "$HOME/.zshrc"
  elif [[ -f "$HOME/.bashrc" ]]; then
    echo "$HOME/.bashrc"
  elif [[ -f "$HOME/.profile" ]]; then
    echo "$HOME/.profile"
  else
    echo ""
  fi
}

prompt_for_key() {
  if ! { : </dev/tty; } 2>/dev/null; then   # -r only stats; this actually opens it
    echo "ERROR: No SAIA API key given and no terminal to ask on." >&2
    echo "Set it: SAIA_API_KEY=\"your-key\" ./add-saia-mini-swe-agent.sh" >&2
    echo "Get one at https://chat-ai.academiccloud.de/" >&2
    exit 1
  fi
  local key=""
  for _ in 1 2 3; do
    read -rsp "GWDG SAIA API key (input hidden): " key </dev/tty
    echo >&2
    key="${key//[[:space:]]/}"   # paste hygiene; SAIA keys carry no whitespace
    if [[ -n "$key" ]]; then
      export SAIA_API_KEY="$key"
      return
    fi
    echo "Key cannot be empty." >&2
  done
  echo "ERROR: no key entered." >&2
  exit 1
}

# ── Obtain API key ───────────────────────────────────────────────────
if [[ -n "$KEY" ]]; then
  SAIA_KEY="$KEY"
elif [[ -n "${SAIA_API_KEY:-}" ]]; then
  SAIA_KEY="$SAIA_API_KEY"
elif [[ -n "$KEY_FILE" ]]; then
  if [[ ! -f "$KEY_FILE" ]]; then
    echo "ERROR: Key file not found: $KEY_FILE" >&2
    exit 1
  fi
  # Try to read as JSON (opencode auth.json format)
  if command -v python3 &>/dev/null; then
    SAIA_KEY=$(python3 -c "import json; d=json.load(open('$KEY_FILE')); print(d.get('saia-gwdg',{}).get('key',''))" 2>/dev/null || echo "")
  fi
  # Fallback: read first line
  if [[ -z "$SAIA_KEY" ]]; then
    SAIA_KEY=$(head -n 1 "$KEY_FILE" 2>/dev/null || echo "")
  fi
else
  SAIA_KEY="$(key_from_config)"
  if [[ -n "$SAIA_KEY" ]]; then
    echo "Reusing the SAIA key already in your shell rc (pass --key to replace it)."
  else
    prompt_for_key
    SAIA_KEY="$SAIA_API_KEY"
  fi
fi

if [[ -z "$SAIA_KEY" ]]; then
  echo "ERROR: SAIA_API_KEY is empty." >&2
  exit 1
fi

# ── Load models ──────────────────────────────────────────────────────
if [[ ! -f "$MODELS_FILE" ]]; then
  echo "ERROR: Models file not found: $MODELS_FILE" >&2
  exit 1
fi

MODELS=()
while IFS= read -r model || [[ -n "$model" ]]; do
  [[ -z "$model" || "$model" =~ ^# ]] && continue
  MODELS+=("$model")
done < "$MODELS_FILE"

if [[ ${#MODELS[@]} -eq 0 ]]; then
  echo "ERROR: No models found in $MODELS_FILE" >&2
  exit 1
fi

DEFAULT_MODEL="${SAIA_DEFAULT_MODEL:-deepseek-v4-flash-0731}"

# ── Check/install mini-swe-agent ─────────────────────────────────────
if ! command -v mini &>/dev/null; then
  if ! command -v pip &>/dev/null && ! command -v pip3 &>/dev/null; then
    echo "ERROR: neither pip nor pip3 found — install Python/pip first" >&2
    exit 1
  fi

  if [[ $ASSUME_YES -eq 1 ]]; then
    :  # --yes: install without asking
  elif [[ -t 0 ]]; then
    read -r -p "mini-swe-agent not found — install it via pip? [y/N] " reply
    if [[ $reply != [yY]* ]]; then
      echo "Aborted." >&2
      exit 1
    fi
  else
    echo "mini-swe-agent not found and not in TTY mode — use --yes to auto-install" >&2
    exit 1
  fi

  echo "Installing mini-swe-agent via pip..."
  if command -v pip &>/dev/null; then
    pip install mini-swe-agent
  else
    pip3 install mini-swe-agent
  fi

  if ! command -v mini &>/dev/null; then
    echo "ERROR: mini-swe-agent installed but 'mini' not found in PATH" >&2
    echo "Add the pip bin dir to your PATH, or use: python3 -m pip install --user mini-swe-agent" >&2
    exit 1
  fi
  echo "mini-swe-agent installed successfully"
fi

# ── Persist the key to the shell rc ──────────────────────────────────
# mini.yaml references "$SAIA_API_KEY" from the process environment, so the key
# must be present when `mini` runs. Persist it (idempotently) to the shell rc.
RC="$(detect_shell_rc)"
if [[ -n "$RC" ]]; then
  touch "$RC"
  if grep -qE '^[[:space:]]*export[[:space:]]+SAIA_API_KEY=' "$RC"; then
    sed -i.bak "s|^[[:space:]]*export[[:space:]]\+SAIA_API_KEY=.*|export SAIA_API_KEY='$SAIA_KEY'|" "$RC"
    rm -f "$RC.bak"
  else
    printf '\n# GWDG SAIA API key (added by mini-swe-agent-saia-gwdg)\nexport SAIA_API_KEY=%s\n' "'$SAIA_KEY'" >> "$RC"
  fi
  echo "Persisted SAIA_API_KEY to $RC"
else
  echo "WARNING: no shell rc detected — export SAIA_API_KEY yourself before running mini." >&2
fi

# ── Write the config artifacts ───────────────────────────────────────
CONFIG_DIR="${MSWEA_GLOBAL_CONFIG_DIR:-$HOME/.config/mini-swe-agent}"
mkdir -p "$CONFIG_DIR"

backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local bak="$f.bak-$(date +%Y%m%d%H%M%S)"
    cp "$f" "$bak"
    echo "Backed up existing $f to $bak"
  fi
}

# 1) mini.yaml — custom agent config pointing litellm at SAIA
# MSWEA_MINI_CONFIG_PATH REPLACES mini's builtin mini.yaml (no merge), so the
# file must be a full config: merge the SAIA overrides onto the builtin with
# mini's own python, using mini's own recursive_merge (same as `-c a -c b`).
# ponytail: builtin templates are frozen at install time; re-run after upgrading mini.
MINI_PY=""
for py in "$(dirname "$(readlink -f "$(command -v mini)")")/python" python3; do
  if MSWEA_SILENT_STARTUP=1 "$py" -c 'import minisweagent' &>/dev/null; then
    MINI_PY="$py"
    break
  fi
done
if [[ -z "$MINI_PY" ]]; then
  echo "ERROR: no python with minisweagent found (tried the one next to 'mini' and python3)" >&2
  exit 1
fi

MINI_YAML="$CONFIG_DIR/mini.yaml"
backup_if_exists "$MINI_YAML"
sed -e "s|{{MODEL_NAME}}|$DEFAULT_MODEL|g" -e "s|{{BASE_URL}}|$SAIA_BASE_URL|g" "$MINI_YAML_TMPL" > "$MINI_YAML.saia"
MSWEA_SILENT_STARTUP=1 MSWEA_GLOBAL_CONFIG_DIR="$CONFIG_DIR" \
"$MINI_PY" - "$MINI_YAML.saia" "$MINI_YAML" <<'PYEOF'
import sys, yaml
from minisweagent.config import builtin_config_dir
from minisweagent.utils.serialize import recursive_merge
base = yaml.safe_load((builtin_config_dir / "mini.yaml").read_text())
saia = yaml.safe_load(open(sys.argv[1]))
with open(sys.argv[2], "w") as f:
    f.write("# Generated by mini-swe-agent-saia-gwdg: mini's builtin mini.yaml + SAIA model block.\n"
            "# Re-run the installer after upgrading mini-swe-agent.\n")
    yaml.safe_dump(recursive_merge(base, saia), f, sort_keys=False, allow_unicode=True, width=1000)
PYEOF
rm -f "$MINI_YAML.saia"
chmod 600 "$MINI_YAML"

# 2) model_registry.json — litellm registry for cost tracking
REGISTRY="$CONFIG_DIR/model_registry.json"
backup_if_exists "$REGISTRY"
# Build the registry with python3 (guaranteed present: mini-swe-agent needs it)
# so the JSON is always valid, then splice it into the template.
MODELS_JSON="$(python3 - "$REGISTRY_TMPL" "${MODELS[@]}" <<'PYEOF'
import json, sys
tmpl = sys.argv[1]
models = sys.argv[2:]
registry = {m: {"max_tokens": 4096, "input_cost_per_token": 0.0,
                "output_cost_per_token": 0.0, "litellm_provider": "openai",
                "mode": "chat"} for m in models}
body = json.dumps(registry, indent=2)
print(open(tmpl).read().replace("{{MODELS_JSON}}", body), end="")
PYEOF
)"
printf '%s' "$MODELS_JSON" > "$REGISTRY"
chmod 600 "$REGISTRY"

# 3) .env — global config so `mini` picks up the SAIA setup
ENV_FILE="$CONFIG_DIR/.env"
backup_if_exists "$ENV_FILE"
touch "$ENV_FILE"
set_env() {
  local k="$1" v="$2"
  if grep -qE "^[[:space:]]*${k}=" "$ENV_FILE"; then
    sed -i.bak "s|^[[:space:]]*${k}=.*|${k}=${v}|" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}
set_env "MSWEA_MODEL_NAME" "$DEFAULT_MODEL"
# mini does not expand env vars in mini.yaml, but its .env goes through
# python-dotenv, which does: litellm (custom_llm_provider=openai) reads
# OPENAI_API_KEY. ponytail: an OPENAI_API_KEY already exported wins (dotenv
# override=False); unset it when running mini if you have one.
set_env "OPENAI_API_KEY" '${SAIA_API_KEY}'
set_env "MSWEA_MINI_CONFIG_PATH" "$MINI_YAML"
set_env "LITELLM_MODEL_REGISTRY_PATH" "$REGISTRY"
set_env "MSWEA_COST_TRACKING" "ignore_errors"
set_env "MSWEA_GLOBAL_CONFIG_DIR" "$CONFIG_DIR"
set_env "MSWEA_CONFIGURED" "true"
chmod 600 "$ENV_FILE"

echo ""
echo "✓ GWDG SAIA provider configured for mini-swe-agent!"
echo "  Config dir: $CONFIG_DIR"
echo "  Base URL: $SAIA_BASE_URL"
echo "  Default model: $DEFAULT_MODEL"
echo "  Models: ${#MODELS[@]} ready SAIA models"
echo ""
echo "Usage: mini                              # SAIA is the default model"
echo "       mini -m <model>                   # pick another SAIA model"
echo "       mini -m qwen3-coder-next -t 'task'"
