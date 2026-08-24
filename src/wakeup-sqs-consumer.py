#!/usr/bin/env python3
#
# wakeup-sqs-consumer.py — consome fila SQS de wakeups remotos e acorda slots
# HMVIP localmente via wakeup-client.sh.
#
# Uso:
#   export WAKEUP_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/.../hmvip-luna-wakeup-prod
#   export HMVIP_WAKEUP_SECRET=<segredo>
#   python3 packages/agent-guard-core/src/wakeup-sqs-consumer.py
#
# Ambiente:
#   WAKEUP_QUEUE_URL       — URL da fila SQS (obrigatória).
#   HMVIP_WAKEUP_SECRET    — segredo do daemon wakeup local (obrigatório).
#   AWS_REGION             — região da fila (default us-east-1).
#   WAKEUP_CLIENT_PATH     — caminho para wakeup-client.sh (auto-detect).
#   LOG_LEVEL              — DEBUG|INFO|WARN|ERROR (default INFO).

import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path

import boto3


LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("wakeup-sqs-consumer")

WAKEUP_QUEUE_URL = os.environ.get("WAKEUP_QUEUE_URL", "")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
WAKEUP_SECRET = os.environ.get("HMVIP_WAKEUP_SECRET", "")


def resolve_wakeup_client() -> str:
    """Resolve o caminho absoluto para wakeup-client.sh."""
    explicit = os.environ.get("WAKEUP_CLIENT_PATH", "")
    if explicit:
        return explicit

    # Mesmo diretório deste script.
    script_dir = Path(__file__).resolve().parent
    candidate = script_dir / "wakeup-client.sh"
    if candidate.exists():
        return str(candidate)

    # Repo padrão do worktree kimi3.
    candidate = Path("/home/hmvip-dev/hmvip-ia-kimi3/packages/agent-guard-core/src/wakeup-client.sh")
    if candidate.exists():
        return str(candidate)

    raise FileNotFoundError("wakeup-client.sh não encontrado; defina WAKEUP_CLIENT_PATH")


def process_message(body: dict, client_path: str) -> bool:
    """Chama wakeup-client.sh com os dados da mensagem SQS."""
    identity = body.get("identity", "")
    title = body.get("title", "")
    if not identity or not title:
        logger.warning("Payload incompleto: identity=%s title=%s", identity, title)
        return True  # Descarta mensagem inválida.

    cmd = [
        "bash", client_path,
        "--identity", identity,
        "--severity", body.get("severity", "P1"),
        "--title", title,
        "--summary", body.get("summary", ""),
        "--source", body.get("source", "luna-wakeup-remote"),
        "--context", body.get("context", ""),
        "--task", body.get("task", title),
        "--next-step", body.get("next_step", ""),
        "--domain", body.get("domain", "general"),
        "--assigned-by", body.get("assigned_by", "Luna/OpenClaw"),
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            logger.info("Wakeup entregue: %s", result.stdout.strip())
            return True
        logger.error("wakeup-client.sh falhou: %s", result.stderr.strip() or result.stdout.strip())
        return False
    except subprocess.TimeoutExpired:
        logger.error("Timeout ao chamar wakeup-client.sh")
        return False
    except Exception as exc:
        logger.exception("Erro inesperado ao chamar wakeup-client.sh: %s", exc)
        return False


def main() -> int:
    if not WAKEUP_QUEUE_URL:
        logger.error("WAKEUP_QUEUE_URL não definida")
        return 1
    if not WAKEUP_SECRET:
        logger.error("HMVIP_WAKEUP_SECRET não definido")
        return 1

    client_path = resolve_wakeup_client()
    logger.info("Iniciando consumidor SQS: queue=%s region=%s client=%s", WAKEUP_QUEUE_URL, AWS_REGION, client_path)

    sqs = boto3.client("sqs", region_name=AWS_REGION)

    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=WAKEUP_QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=20,
                VisibilityTimeout=30,
                AttributeNames=["All"],
                MessageAttributeNames=["All"],
            )
        except Exception as exc:
            logger.exception("Erro ao receber mensagem do SQS: %s", exc)
            time.sleep(5)
            continue

        messages = response.get("Messages", [])
        if not messages:
            continue

        for msg in messages:
            receipt_handle = msg.get("ReceiptHandle")
            try:
                body = json.loads(msg.get("Body", "{}"))
                logger.debug("Mensagem recebida: %s", body)
                ok = process_message(body, client_path)
            except json.JSONDecodeError as exc:
                logger.error("JSON inválido na mensagem SQS: %s", exc)
                ok = True  # Descarta mensagem mal-formada.

            if ok and receipt_handle:
                try:
                    sqs.delete_message(QueueUrl=WAKEUP_QUEUE_URL, ReceiptHandle=receipt_handle)
                    logger.debug("Mensagem deletada da fila")
                except Exception as exc:
                    logger.exception("Erro ao deletar mensagem: %s", exc)

    return 0


if __name__ == "__main__":
    sys.exit(main())
