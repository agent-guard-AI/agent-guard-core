#!/usr/bin/env python3
"""Local wakeup daemon for HMVIP agent sessions.

Listens only on 127.0.0.1, authenticates requests via HMAC-SHA256 and notifies
locally active IA sessions through:

  - desktop notification (notify-send / osascript / notify2 fallback)
  - terminal tab title update (OSC 0) when a TTY is available
  - pending alert file at .agent-guard/wakeup/<identity>.json

The heartbeat hook reads pending alert files and surfaces them to the running
IA on its next cycle. We deliberately do NOT inject input into kimi-code /
codewhale processes because they do not expose a safe API for that.

Configuration (agent-guard.yaml -> wakeup.*):
  port              int   TCP port (default 17321)
  host              str   bind address (default 127.0.0.1)
  secret_env_var    str   env var holding HMAC secret (default HMVIP_WAKEUP_SECRET)
  alert_ttl_seconds int   seconds before a pending alert is considered stale

Environment:
  HMVIP_WAKEUP_SECRET      shared HMAC secret (required for POST /wakeup)
  HMVIP_WAKEUP_PORT        overrides config port
  HMVIP_WAKEUP_HOST        overrides config host
  HMVIP_DISABLE_WAKEUP     set to 1 to start the daemon in no-op mode
  HMVIP_DISABLE_NOTIFY     set to 1 to skip desktop notifications
"""

from __future__ import annotations

import hmac
import json
import os
import signal
import socket
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Dict, Optional


DEFAULT_PORT = 17321
DEFAULT_HOST = "127.0.0.1"
DEFAULT_SECRET_ENV_VAR = "HMVIP_WAKEUP_SECRET"
DEFAULT_ALERT_TTL_SECONDS = 3600


@dataclass(frozen=True)
class DaemonConfig:
    host: str
    port: int
    secret_env_var: str
    alert_ttl_seconds: int
    repo_root: Path

    def secret(self) -> Optional[str]:
        return os.environ.get(self.secret_env_var) or None


def _detect_repo_root() -> Path:
    cwd = Path.cwd()
    for path in [cwd, *cwd.parents]:
        if (path / "agent-guard.yaml").is_file():
            return path
    return cwd


def _load_yaml_config(repo_root: Path) -> Dict[str, Any]:
    yaml_path = repo_root / "agent-guard.yaml"
    if not yaml_path.is_file():
        return {}
    try:
        import yaml  # type: ignore

        with yaml_path.open("r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _build_config() -> DaemonConfig:
    repo_root = _detect_repo_root()
    cfg = _load_yaml_config(repo_root).get("wakeup", {})

    return DaemonConfig(
        host=os.environ.get("HMVIP_WAKEUP_HOST") or str(cfg.get("host", DEFAULT_HOST)),
        port=int(
            os.environ.get("HMVIP_WAKEUP_PORT")
            or cfg.get("port", DEFAULT_PORT)
        ),
        secret_env_var=str(
            cfg.get("secret_env_var", DEFAULT_SECRET_ENV_VAR)
        ),
        alert_ttl_seconds=int(
            cfg.get("alert_ttl_seconds", DEFAULT_ALERT_TTL_SECONDS)
        ),
        repo_root=repo_root,
    )


def _wakeup_dir(repo_root: Path) -> Path:
    path = repo_root / ".agent-guard" / "wakeup"
    path.mkdir(parents=True, exist_ok=True)
    # Ensure restrictive permissions: only owner can read/write.
    try:
        path.chmod(0o700)
    except OSError:
        pass
    return path


def _pid_path(repo_root: Path) -> Path:
    return _wakeup_dir(repo_root) / "daemon.pid"


def _read_pid_file(path: Path) -> Optional[Dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict) and "pid" in data and "host" in data and "port" in data:
            return data
    except Exception:
        pass
    return None


def _is_daemon_alive(pid: int, host: str, port: int) -> bool:
    """Check if another daemon process is alive and listening."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except Exception:
        return False

    try:
        with socket.create_connection((host, port), timeout=2):
            return True
    except Exception:
        return False


def _claim_pid_file(path: Path, pid: int, host: str, port: int) -> bool:
    try:
        path.write_text(
            json.dumps({"pid": pid, "host": host, "port": port, "ts": time.time()}),
            encoding="utf-8",
        )
        path.chmod(0o600)
        return True
    except Exception:
        return False


def _release_pid_file(path: Path) -> None:
    try:
        path.unlink(missing_ok=True)
    except Exception:
        pass


def _signature(secret: str, body: bytes) -> str:
    return hmac.new(
        secret.encode("utf-8"), body, "sha256"
    ).hexdigest()


def _verify_signature(secret: str, body: bytes, header: str) -> bool:
    expected = _signature(secret, body)
    # Normalize header: accept "<hex>" or "hmac <hex>"; constant-time compare.
    normalized = header.lower().strip()
    if normalized.startswith("hmac "):
        normalized = normalized[5:]
    # Constant-time comparison to avoid timing leaks.
    return hmac.compare_digest(expected.lower(), normalized)


def _send_notification(title: str, message: str, urgency: str = "normal") -> bool:
    if os.environ.get("HMVIP_DISABLE_NOTIFY") == "1":
        return False

    # Linux / freedesktop
    if sys.platform.startswith("linux") and _has_command("notify-send"):
        urgency_flag = {"P0": "critical", "P1": "critical"}.get(urgency, urgency)
        if urgency_flag not in {"low", "normal", "critical"}:
            urgency_flag = "normal"
        cmd = [
            "notify-send",
            "-u", urgency_flag,
            "-i", "dialog-warning",
            title,
            message,
        ]
        return _run_silent(cmd)

    # macOS
    if sys.platform == "darwin" and _has_command("osascript"):
        script = (
            f'display notification {json.dumps(message)} '
            f'with title {json.dumps(title)} sound name "default"'
        )
        return _run_silent(["osascript", "-e", script])

    return False


def _has_command(name: str) -> bool:
    from shutil import which

    return which(name) is not None


def _run_silent(cmd: list) -> bool:
    import subprocess

    try:
        subprocess.run(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
        return True
    except Exception:
        return False


def _update_tab_title(identity: str, title: str) -> bool:
    """Best-effort OSC 0 title update on the current TTY."""
    tty = os.environ.get("SSH_TTY") or os.ttyname(sys.stdout.fileno()) if sys.stdout.isatty() else None
    if not tty:
        return False

    osc = f"\033]0;🚨 [{identity}] {title}\007"
    try:
        with open(tty, "w") as fh:
            fh.write(osc)
        return True
    except OSError:
        return False


def _write_pending_alert(repo_root: Path, identity: str, payload: Dict[str, Any]) -> Path:
    wakeup_dir = _wakeup_dir(repo_root)
    alert_path = wakeup_dir / f"{identity}.json"
    record = {
        "identity": identity,
        "severity": payload.get("severity", "P1"),
        "title": payload.get("title", ""),
        "summary": payload.get("summary", ""),
        "source": payload.get("source", ""),
        "context": payload.get("context", ""),
        "task": payload.get("task", ""),
        "next_step": payload.get("next_step", ""),
        "domain": payload.get("domain", ""),
        "assigned_by": payload.get("assigned_by", "Luna/OpenClaw"),
        "received_at": datetime.now(timezone.utc).isoformat(),
        "expires_at": (
            datetime.now(timezone.utc).timestamp()
            + int(payload.get("ttl_seconds", DEFAULT_ALERT_TTL_SECONDS))
        ),
    }
    alert_path.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    try:
        alert_path.chmod(0o600)
    except OSError:
        pass
    return alert_path


def _cleanup_stale_alerts(repo_root: Path, ttl: int) -> None:
    now = time.time()
    for path in _wakeup_dir(repo_root).glob("*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            expires = data.get("expires_at") or (path.stat().st_mtime + ttl)
            if now > expires:
                path.unlink()
        except Exception:
            pass


class WakeupHandler(BaseHTTPRequestHandler):
    config: DaemonConfig

    def _send_json(self, status: int, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: Any) -> None:
        # Suppress default access logs; rely on structured stderr if needed.
        pass

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json(200, {"ok": True, "daemon": "wakeup", "ts": time.time()})
            return
        self._send_json(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/wakeup":
            self._send_json(404, {"ok": False, "error": "not found"})
            return

        secret = self.config.secret()
        if not secret:
            self._send_json(503, {"ok": False, "error": "wakeup secret not configured"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        sig_header = self.headers.get("X-Hmvip-Wakeup-Signature", "")
        if not _verify_signature(secret, body, sig_header):
            self._send_json(401, {"ok": False, "error": "invalid signature"})
            return

        try:
            payload = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json(400, {"ok": False, "error": "invalid json"})
            return

        identity = str(payload.get("identity", "")).lower()
        if not identity or not identity.replace("-", "").replace("_", "").isalnum():
            self._send_json(400, {"ok": False, "error": "invalid identity"})
            return

        severity = str(payload.get("severity", "P1")).upper()
        title = str(payload.get("title", "Wakeup"))
        summary = str(payload.get("summary", ""))
        source = str(payload.get("source", ""))

        # Best-effort local notifications.
        notified = _send_notification(
            f"[{severity}] {title}",
            f"{summary}\nFonte: {source}",
            urgency=severity,
        )
        tab_updated = _update_tab_title(identity, title)

        alert_path = _write_pending_alert(self.config.repo_root, identity, payload)
        _cleanup_stale_alerts(self.config.repo_root, self.config.alert_ttl_seconds)

        self._send_json(
            200,
            {
                "ok": True,
                "identity": identity,
                "severity": severity,
                "alert_path": str(alert_path),
                "notified": notified,
                "tab_updated": tab_updated,
            },
        )


def main() -> int:
    if os.environ.get("HMVIP_DISABLE_WAKEUP") == "1":
        print("[wakeup-daemon] HMVIP_DISABLE_WAKEUP=1; exiting.", file=sys.stderr)
        return 0

    config = _build_config()
    secret = config.secret()
    if not secret:
        print(
            "[wakeup-daemon] WARN: HMVIP_WAKEUP_SECRET not set. "
            "Daemon will reject all /wakeup requests.",
            file=sys.stderr,
        )

    pid_path = _pid_path(config.repo_root)
    existing = _read_pid_file(pid_path)
    if existing and _is_daemon_alive(
        int(existing["pid"]), str(existing["host"]), int(existing["port"])
    ):
        print(
            f"[wakeup-daemon] already running on "
            f"http://{existing['host']}:{existing['port']} (pid {existing['pid']}); exiting.",
            file=sys.stderr,
        )
        return 0

    # Stale PID file: remove and claim for this process.
    _release_pid_file(pid_path)
    if not _claim_pid_file(pid_path, os.getpid(), config.host, config.port):
        print("[wakeup-daemon] failed to write PID file; exiting.", file=sys.stderr)
        return 1

    WakeupHandler.config = config

    server = HTTPServer((config.host, config.port), WakeupHandler)
    server.allow_reuse_address = True

    def _shutdown(_signum: int, _frame: Any) -> None:
        print("\n[wakeup-daemon] shutting down...", file=sys.stderr)
        _release_pid_file(pid_path)
        server.shutdown()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    print(
        f"[wakeup-daemon] listening on http://{config.host}:{config.port}",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    finally:
        _release_pid_file(pid_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
