#!/usr/bin/env bash
#
# build.sh — pack the live SAIA config into install-mini-swe-agent-saia-gwdg.sh
#
# Reads the current src/add-saia-mini-swe-agent.sh, src/models.txt,
# src/mini.yaml.tmpl, src/model_registry.json.tmpl and the vendored keyring
# (src/saia_keyring.py, src/saia-keyring.sh — from opencode-extras) and emits
# a single self-contained installer that can be copied to other devices.
# Rerun this after ANY change to those files, and commit both.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OUT="install-mini-swe-agent-saia-gwdg.sh"
MANIFEST=(
  src/add-saia-mini-swe-agent.sh
  src/models.txt
  src/mini.yaml.tmpl
  src/model_registry.json.tmpl
  src/saia-keyring.sh
  src/saia_keyring.py
)

# ── Sanity checks ────────────────────────────────────────────────────
for f in "${MANIFEST[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing source file: $f" >&2
    exit 1
  fi
  if grep -qF "__MSA_EOF__" "$f"; then
    echo "ERROR: delimiter '__MSA_EOF__' occurs in $f — pick a different delimiter" >&2
    exit 1
  fi
  if [[ -n "$(tail -c 1 "$f")" ]]; then
    echo "ERROR: $f lacks a trailing newline (heredoc packing would add one)" >&2
    exit 1
  fi
done

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
git diff --quiet HEAD -- "${MANIFEST[@]}" 2>/dev/null || DIRTY="-dirty"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMP_OUT="$(mktemp "$OUT.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

# ── Header (interpolates the stamp) ──────────────────────────────────
cat >"$TMP_OUT" <<MSA_GEN_HEADER
#!/usr/bin/env bash
#
# install-mini-swe-agent-saia-gwdg.sh — GENERATED FILE, DO NOT EDIT.
# Regenerate with: ./build.sh  (in the mini-swe-agent-saia-gwdg repo)
# Source: mini-swe-agent-saia-gwdg commit $COMMIT$DIRTY, packed $STAMP
#
# Installs the GWDG SAIA setup for mini-swe-agent: provider + models + default model.

MSA_GEN_HEADER

# ── Static installer body ────────────────────────────────────────────
cat >>"$TMP_OUT" <<'MSA_GEN_BODY'
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: SAIA_API_KEY="your-key" bash install-mini-swe-agent-saia-gwdg.sh [OPTIONS]

Installs the GWDG SAIA setup for mini-swe-agent:
  - Installs mini-swe-agent (if missing) via pip
  - Writes ~/.config/mini-swe-agent/.env (global config)
  - Writes ~/.config/mini-swe-agent/mini.yaml (agent config)
  - Writes ~/.config/mini-swe-agent/model_registry.json (litellm registry)

Options:
  -y, --yes           answer yes to prompts (e.g. installing mini-swe-agent)
      --key <value>   SAIA API key (overrides SAIA_API_KEY env)
      --key-file <p>  file containing the SAIA API key
      --extra-keys <k2,k3>      with --keyring: extra SAIA keys to swap to
                                (or SAIA_API_KEYS_EXTRA, which keeps them out of ps)
      --extra-keys-file <path>  with --keyring: extra keys from {"keys": [...]} (opencode's
                                saia-gwdg-keys.json) or one key per line
      --keyring                 opt in: route through the local key-rotating proxy
      --no-keyring              talk to SAIA directly with one key (the default)
  -h, --help          show this help

The API key is taken from --key, --key-file or the SAIA_API_KEY environment
variable; if none of them is set, you are prompted for it. The key is persisted
to your shell rc (as SAIA_API_KEY) so mini-swe-agent can resolve it at runtime.
Existing config files are backed up to .bak-<timestamp>/ first.

With --keyring mini talks to a local proxy (saia-keyring, 127.0.0.1:8788) that swaps
to the next key when the active one is revoked, drained or rate limited.
USAGE
}

ASSUME_YES=0
KEY=""
KEY_FILE=""
KEYRING_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --key|--key-file)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      if [[ $1 == --key ]]; then KEY="$2"; else KEY_FILE="$2"; fi
      shift 2
      ;;
    --extra-keys|--extra-keys-file)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      KEYRING_ARGS+=("$1" "$2")
      shift 2
      ;;
    --keyring|--no-keyring) KEYRING_ARGS+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── Unpack the bundled source files ──────────────────────────────────
# Into a temp dir, not next to the installer: this file is meant to be copied
# to a fresh machine on its own, and it must not litter (or overwrite) a repo
# checkout it happens to be run from.
EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
mkdir -p "$EXTRACT_DIR/src"
MSA_GEN_BODY

# ── Append the packed source files ───────────────────────────────────
echo "" >>"$TMP_OUT"
echo "# ── Packed source files ────────────────────────────────────────────" >>"$TMP_OUT"

for f in "${MANIFEST[@]}"; do
  echo "cat >\"\$EXTRACT_DIR/$f\" <<'__MSA_EOF__'" >>"$TMP_OUT"
  cat "$f" >>"$TMP_OUT"
  echo "__MSA_EOF__" >>"$TMP_OUT"
  echo "" >>"$TMP_OUT"
done

# ── Static installer tail: run what we just unpacked ──────────────────
cat >>"$TMP_OUT" <<'MSA_GEN_TAIL'
chmod +x "$EXTRACT_DIR/src/add-saia-mini-swe-agent.sh"
CHILD_ARGS=()
if [[ -n "$KEY" ]]; then CHILD_ARGS+=(--key "$KEY"); fi
if [[ -n "$KEY_FILE" ]]; then CHILD_ARGS+=(--key-file "$KEY_FILE"); fi
if [[ $ASSUME_YES -eq 1 ]]; then CHILD_ARGS+=(--yes); fi
CHILD_ARGS+=(${KEYRING_ARGS[@]+"${KEYRING_ARGS[@]}"})
# ${a[@]+"${a[@]}"}: bash 3.2 (stock macOS) calls an empty array unbound under set -u
"$EXTRACT_DIR/src/add-saia-mini-swe-agent.sh" ${CHILD_ARGS[@]+"${CHILD_ARGS[@]}"}
MSA_GEN_TAIL

# ── Finalize ─────────────────────────────────────────────────────────
mv "$TMP_OUT" "$OUT"
chmod +x "$OUT"

echo "Generated: $OUT"
echo "Commit: $COMMIT$DIRTY"
echo "Timestamp: $STAMP"
