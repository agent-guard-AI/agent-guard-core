#!/usr/bin/env bash
#
# wakeup-sqs-consumer.sh — wrapper para rodar o consumidor SQS de wakeups.
#
# Uso:
#   export WAKEUP_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/.../hmvip-luna-wakeup-prod
#   export HMVIP_WAKEUP_SECRET=<segredo>
#   bash packages/agent-guard-core/src/wakeup-sqs-consumer.sh
#
# Para rodar como serviço systemd --user:
#   ExecStart=%h/hmvip-ia-kimi3/packages/agent-guard-core/src/wakeup-sqs-consumer.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"

if [[ -z "${WAKEUP_QUEUE_URL:-}" ]]; then
  echo "[wakeup-sqs-consumer] WAKEUP_QUEUE_URL não definida" >&2
  exit 1
fi

if [[ -z "${HMVIP_WAKEUP_SECRET:-}" ]]; then
  echo "[wakeup-sqs-consumer] HMVIP_WAKEUP_SECRET não definido" >&2
  exit 1
fi

exec "$PYTHON" "$SCRIPT_DIR/wakeup-sqs-consumer.py"
