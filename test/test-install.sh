#!/usr/bin/env bash
#
# test-install.sh — smoke-test the mini-swe-agent-saia-gwdg installer.
#
# Runs src/add-saia-mini-swe-agent.sh against a throwaway HOME / MSWEA_GLOBAL_CONFIG_DIR /
# SAIA_SHELL_RC so it never touches ~/.config/mini-swe-agent or the real shell rc, and never
# installs mini-swe-agent (a real mini must be present: the installer merges its builtin
# mini.yaml). Verifies the generated .env, mini.yaml
# and model_registry.json, that the key is persisted to the fake shell rc, and that the fake
# SAIA endpoint answers. Then checks the automatic key swap: with two keys, the first one
# revoked, mini's api_base is pointed at the local saia-keyring proxy and a request through
# it fails over to the second key. The proxy is started with SAIA_KEYRING_SERVICE=none, so
# no systemd unit or real shell rc is touched.
#
#   bash test/test-install.sh
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

WORK="$(mktemp -d)"
export HOME="$WORK/home"
export MSWEA_GLOBAL_CONFIG_DIR="$WORK/config"
export SAIA_SHELL_RC="$WORK/rc"
export SAIA_KEYRING_SERVICE=none
mkdir -p "$HOME" "$MSWEA_GLOBAL_CONFIG_DIR"
touch "$SAIA_SHELL_RC"

command -v mini >/dev/null || { echo "FAIL: mini-swe-agent not installed (uv tool install mini-swe-agent)" >&2; exit 1; }

cleanup() {
  [[ -n "${FAKE_PID:-}" ]] && kill "$FAKE_PID" 2>/dev/null || true
  if [[ -n "${KR_PORT:-}" ]]; then
    curl -s "http://127.0.0.1:$KR_PORT/_keyring/health" \
      | python3 -c 'import json,os,sys; os.kill(json.load(sys.stdin)["pid"], 15)' 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── Start the fake SAIA ──────────────────────────────────────────────
FAKE_DEAD_KEYS=dead-key SEEN_FILE="$WORK/seen" python3 ./fake-saia.py >"$WORK/port" 2>"$WORK/fake.log" &
FAKE_PID=$!
for _ in $(seq 40); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
PORT="$(cat "$WORK/port")"
[[ -n "$PORT" ]] || { echo "FAIL: fake-saia did not start" >&2; cat "$WORK/fake.log" >&2; exit 1; }
echo "fake-saia on port $PORT"

# ── Run the installer source against the fake ────────────────────────
SAIA_API_KEY=dummy bash ../src/add-saia-mini-swe-agent.sh >"$WORK/install.log" 2>&1 || {
  echo "FAIL: add-saia-mini-swe-agent.sh exited non-zero" >&2
  cat "$WORK/install.log" >&2
  exit 1
}

fail() { echo "FAIL: $1" >&2; echo "--- install.log ---" >&2; cat "$WORK/install.log" >&2; exit 1; }

ENV_FILE="$MSWEA_GLOBAL_CONFIG_DIR/.env"
MINI_YAML="$MSWEA_GLOBAL_CONFIG_DIR/mini.yaml"
REGISTRY="$MSWEA_GLOBAL_CONFIG_DIR/model_registry.json"

[[ -f "$ENV_FILE" ]] || fail ".env not written"
grep -q '^MSWEA_MODEL_NAME=deepseek-v4-flash-0731$' "$ENV_FILE" \
  || fail "MSWEA_MODEL_NAME missing/incorrect"
grep -q "^MSWEA_MINI_CONFIG_PATH=$MINI_YAML$" "$ENV_FILE" \
  || fail "MSWEA_MINI_CONFIG_PATH missing"
grep -q "^LITELLM_MODEL_REGISTRY_PATH=$REGISTRY$" "$ENV_FILE" \
  || fail "LITELLM_MODEL_REGISTRY_PATH missing"
grep -q '^MSWEA_COST_TRACKING=ignore_errors$' "$ENV_FILE" \
  || fail "MSWEA_COST_TRACKING missing"
grep -qF 'OPENAI_API_KEY=${SAIA_API_KEY}' "$ENV_FILE" \
  || fail "OPENAI_API_KEY interpolation missing"

[[ -f "$MINI_YAML" ]] || fail "mini.yaml not written"
grep -q '^  model_name: deepseek-v4-flash-0731$' "$MINI_YAML" \
  || fail "default model not set in mini.yaml"
grep -q '^    custom_llm_provider: openai$' "$MINI_YAML" \
  || fail "custom_llm_provider missing"
grep -q '^    api_base: https://chat-ai.academiccloud.de/v1$' "$MINI_YAML" \
  || fail "api_base missing"
grep -q '^  system_template:' "$MINI_YAML" && grep -q '^  instance_template:' "$MINI_YAML" \
  || fail "builtin templates not merged in (mini would reject the config)"
! grep -q 'api_key' "$MINI_YAML" || fail "api_key must not be in mini.yaml (mini does not expand env vars)"

[[ -f "$REGISTRY" ]] || fail "model_registry.json not written"
grep -q '"deepseek-v4-flash-0731"' "$REGISTRY" \
  || fail "default model not in registry"
grep -q '"qwen3-coder-next"' "$REGISTRY" \
  || fail "model list not written to registry"
grep -q '"litellm_provider": "openai"' "$REGISTRY" \
  || fail "litellm_provider missing"

grep -q "export SAIA_API_KEY='dummy'" "$SAIA_SHELL_RC" \
  || fail "key not persisted to shell rc"

# ── Verify the fake endpoint answers (models list) ───────────────────
MODELS_JSON_OUT="$(curl -s -H "Authorization: Bearer dummy" "http://127.0.0.1:$PORT/v1/models")"
echo "$MODELS_JSON_OUT" | grep -q "fake-model" || fail "fake endpoint did not list models"

echo "PASS: .env + mini.yaml + model_registry.json written, key persisted, fake endpoint answered"

# ── SAIA_BASE_URL override (used by the benchmark's local gateway) ─────
OV="$WORK/override"; mkdir -p "$OV/home"
HOME="$OV/home" MSWEA_GLOBAL_CONFIG_DIR="$OV/config" SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" \
  SAIA_API_KEY=dummy bash ../src/add-saia-mini-swe-agent.sh >"$WORK/override.log" 2>&1 \
  || fail "installer failed with SAIA_BASE_URL set"
grep -q "api_base: .*http://127.0.0.1:$PORT/v1" "$OV/config/mini.yaml" \
  || fail "SAIA_BASE_URL not written to mini.yaml"
grep -q "chat-ai.academiccloud.de/v1" "$OV/config/mini.yaml" && fail "production URL left in mini.yaml"
echo "PASS: SAIA_BASE_URL override"

# ── Automatic key swap: two keys, the first one revoked ───────────────
KR="$WORK/keyring"; mkdir -p "$KR/home"
KR_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
HOME="$KR/home" MSWEA_GLOBAL_CONFIG_DIR="$KR/config" SAIA_SHELL_RC="$KR/rc" SAIA_KEYRING_PORT="$KR_PORT" \
  SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" SAIA_API_KEY=dead-key \
  bash ../src/add-saia-mini-swe-agent.sh --keyring --extra-keys good-key >"$WORK/keyring.log" 2>&1 \
  || { cat "$WORK/keyring.log" >&2; fail "installer failed with --keyring"; }
grep -q "^    api_base: http://127.0.0.1:$KR_PORT/v1$" "$KR/config/mini.yaml" \
  || { cat "$WORK/keyring.log" >&2; fail "mini.yaml api_base not pointed at the keyring proxy"; }
KR_CFG="$KR/home/.config/saia-keyring/keyring.json"
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$KR_CFG")" == 0o600 ]] \
  || fail "keyring.json is not chmod 600"
: >"$WORK/seen"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer dead-key" \
  "http://127.0.0.1:$KR_PORT/v1/models")"
[[ "$CODE" == 200 ]] || fail "request through the keyring proxy returned $CODE"
[[ "$(paste -sd, "$WORK/seen")" == "dead-key,good-key" ]] \
  || fail "proxy did not fail over from the revoked key (saw: $(paste -sd, "$WORK/seen"))"
echo "PASS: automatic key swap (revoked key -> next key through the local proxy)"
