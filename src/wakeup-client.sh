#!/usr/bin/env bash
#
# wakeup-client.sh — client for the local HMVIP wakeup daemon.
#
# Workflows/P0 analyses call this script to surface critical alerts in the
# terminal of an active IA session. The request is authenticated with HMAC-SHA256
# using the shared secret HMVIP_WAKEUP_SECRET.
#
# Usage:
#   bash packages/agent-guard-core/src/wakeup-client.sh \
#     --identity kimi3 \
#     --severity P0 \
#     --title "Ledger reconciliation failed" \
#     --summary "Divergence of R$ 1.23 detected." \
#     --source "ledger-reconciliation.yml"
#
# The script is fail-soft: if the daemon is not running or the secret is
# missing, it logs a warning and exits 0 so the workflow is not blocked.
#
# Configuration precedence:
#   1. Environment variables HMVIP_WAKEUP_HOST / HMVIP_WAKEUP_PORT
#   2. agent-guard.yaml -> wakeup.host / wakeup.port
#   3. Defaults 127.0.0.1:17321

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IDENTITY=""
SEVERITY="P1"
TITLE=""
SUMMARY=""
SOURCE=""
CONTEXT=""
TASK=""
NEXT_STEP=""
DOMAIN=""
ASSIGNED_BY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --severity) SEVERITY="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --source) SOURCE="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;;
    --next-step) NEXT_STEP="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --assigned-by) ASSIGNED_BY="$2"; shift 2 ;;
    *) echo "[wakeup-client] unknown arg: $1" >&2; shift ;;
  esac
done

if [[ -z "$IDENTITY" || -z "$TITLE" ]]; then
  echo "[wakeup-client] usage: --identity <slot> --title <title> [--severity P0|P1|P2] [--summary ...] [--source ...]" >&2
  exit 0
fi

if [[ -z "${HMVIP_WAKEUP_SECRET:-}" ]]; then
  echo "[wakeup-client] HMVIP_WAKEUP_SECRET not set; skipping wakeup." >&2
  exit 0
fi

# Resolve repo root.
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -z "$REPO_ROOT" ]]; then
  echo "[wakeup-client] could not detect repo root; skipping wakeup." >&2
  exit 0
fi

# Resolve host/port: env wins, then agent-guard.yaml, then defaults.
DEFAULT_HOST="127.0.0.1"
DEFAULT_PORT="17321"
YAML_HOST=""
YAML_PORT=""
if [[ -f "$REPO_ROOT/agent-guard.yaml" ]] && command -v python3 >/dev/null 2>&1; then
  YAML_HOST="$(python3 -c '
import yaml, sys
try:
    cfg = yaml.safe_load(open(sys.argv[1]))
    print(cfg.get("wakeup", {}).get("host", ""))
except Exception:
    pass
' "$REPO_ROOT/agent-guard.yaml" 2>/dev/null)"
  YAML_PORT="$(python3 -c '
import yaml, sys
try:
    cfg = yaml.safe_load(open(sys.argv[1]))
    print(cfg.get("wakeup", {}).get("port", ""))
except Exception:
    pass
' "$REPO_ROOT/agent-guard.yaml" 2>/dev/null)"
fi
WAKEUP_HOST="${HMVIP_WAKEUP_HOST:-${YAML_HOST:-$DEFAULT_HOST}}"
WAKEUP_PORT="${HMVIP_WAKEUP_PORT:-${YAML_PORT:-$DEFAULT_PORT}}"

URL="http://${WAKEUP_HOST}:${WAKEUP_PORT}/wakeup"

# Build JSON payload.
PAYLOAD="$(python3 -c '
import json, sys
print(json.dumps({
    "identity": sys.argv[1],
    "severity": sys.argv[2],
    "title": sys.argv[3],
    "summary": sys.argv[4],
    "source": sys.argv[5],
    "context": sys.argv[6],
    "task": sys.argv[7],
    "next_step": sys.argv[8],
    "domain": sys.argv[9],
    "assigned_by": sys.argv[10],
}))
' "$IDENTITY" "$SEVERITY" "$TITLE" "$SUMMARY" "$SOURCE" "$CONTEXT" "$TASK" "$NEXT_STEP" "$DOMAIN" "$ASSIGNED_BY")"

# Compute HMAC over the exact bytes that curl will send (no trailing newline).
SIGNATURE="$(printf '%s' "$PAYLOAD" | python3 -c '
import hmac, hashlib, os, sys
secret = os.environ.get("HMVIP_WAKEUP_SECRET", "")
body = sys.stdin.buffer.read()
print(hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest())
')"

if [[ -z "$SIGNATURE" ]]; then
  echo "[wakeup-client] failed to compute HMAC; skipping wakeup." >&2
  exit 0
fi

# Send request.
if ! command -v curl >/dev/null 2>&1; then
  echo "[wakeup-client] curl not available; skipping wakeup." >&2
  exit 0
fi

RESPONSE="$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST \
  -H 'Content-Type: application/json' \
  -H "X-Hmvip-Wakeup-Signature: ${SIGNATURE}" \
  --max-time 5 \
  --data "$PAYLOAD" \
  "$URL" 2>/dev/null)"
[[ -z "$RESPONSE" ]] && RESPONSE="000"

if [[ "$RESPONSE" == "200" ]]; then
  echo "[wakeup-client] wakeup sent to ${IDENTITY} via ${URL}."
elif [[ "$RESPONSE" == "000" ]]; then
  echo "[wakeup-client] daemon not reachable at ${URL}; skipping wakeup." >&2
else
  echo "[wakeup-client] daemon returned HTTP ${RESPONSE}; skipping wakeup." >&2
fi

exit 0
