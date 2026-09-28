#!/usr/bin/env bash
# migrate-lease-schema.sh — migrador one-shot do session storage para o
# schema de identidade de lease (Wave B, ADR-0064).
#
# Uso:
#   bash tools/migrate-lease-schema.sh [--repo <path>] [--dry-run] [--rollback]
#
# Default: para cada session JSON sem 'lease_schema', marca lease_schema=2 e,
# quando a sessão está active com PID vivo, preenche pid_starttime/boot_id/
# last_activity_mono/activity_boot_id com os valores ATUAIS do processo
# (best effort — a sessão continua válida; os campos só endurecem checagens
# futuras). Sessões free/released só são marcadas.
#
# --dry-run : reporta o que faria sem escrever.
# --rollback: remove os campos aditivos (pid_starttime, boot_id,
#             last_activity_mono, activity_boot_id, lease_schema), voltando
#             ao schema legado. Nunca toca em outros campos.
#
# Fail-safe: arquivo malformado é pulado com aviso (nunca destruído).
# Escrita atômica (tmp + os.replace). Idempotente.

set -euo pipefail

REPO_ROOT=""
DRY_RUN=0
ROLLBACK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO_ROOT="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --rollback) ROLLBACK=1; shift ;;
        -h|--help)
            sed -n '2,16p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) echo "❌ argumento desconhecido: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "${REPO_ROOT}" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

STORAGE="${REPO_ROOT}/.kiro/locks/agent-sessions"
if [[ ! -d "${STORAGE}" ]]; then
    echo "⚠️  storage não encontrado: ${STORAGE} (nada a migrar)"
    exit 0
fi

export MIG_DRY_RUN="${DRY_RUN}" MIG_ROLLBACK="${ROLLBACK}"

python3 - "${STORAGE}" <<'PY'
import json, os, sys, time

storage = sys.argv[1]
dry = os.environ.get("MIG_DRY_RUN") == "1"
rollback = os.environ.get("MIG_ROLLBACK") == "1"
ADDED = ("pid_starttime", "boot_id", "last_activity_mono", "activity_boot_id", "lease_schema")

def boot_id():
    try:
        with open("/proc/sys/kernel/random/boot_id") as fh:
            return fh.read().strip()
    except Exception:
        return None

def proc_starttime(pid):
    try:
        with open("/proc/%d/stat" % int(pid)) as fh:
            return int(fh.read().rsplit(")", 1)[1].split()[19])
    except Exception:
        return None

def proc_alive(pid):
    try:
        os.kill(int(pid), 0)
    except Exception:
        return False
    try:
        with open("/proc/%d/stat" % int(pid)) as fh:
            state = fh.read().rsplit(")", 1)[1].split()[0]
        return state not in ("Z", "X", "x")
    except Exception:
        return True

migrated = skipped = malformed = 0
for name in sorted(os.listdir(storage)):
    if not name.endswith(".json"):
        continue
    path = os.path.join(storage, name)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
    except Exception:
        print(f"⚠️  {name}: JSON malformado — pulado (não destruído)")
        malformed += 1
        continue

    changed = False
    if rollback:
        for key in ADDED:
            if key in data:
                del data[key]
                changed = True
        action = "rollback"
    else:
        if data.get("lease_schema") == 2:
            skipped += 1
            continue
        boot = boot_id()
        pid = data.get("pid")
        if data.get("status") == "active" and pid and proc_alive(pid):
            st = proc_starttime(pid)
            if st is not None:
                data["pid_starttime"] = st
                changed = True
            if boot:
                data["boot_id"] = boot
                data["activity_boot_id"] = boot
                changed = True
            data["last_activity_mono"] = time.monotonic()
            changed = True
        data["lease_schema"] = 2
        changed = True
        action = "migrate"

    if not changed:
        skipped += 1
        continue
    if dry:
        print(f"[dry-run] {action}: {name}")
        migrated += 1
        continue
    tmp = path + ".tmp.migrate"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, path)
    migrated += 1
    print(f"✅ {action}: {name}")

verb = "dry-run " if dry else ""
print(f"\n{verb}migrados={migrated} já-ok={skipped} malformados={malformed}")
PY
