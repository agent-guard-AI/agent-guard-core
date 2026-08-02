#!/usr/bin/env bash
#
# cleanup-sessions.sh — cleanup lifecycle-aware de ~/.kimi-code/sessions/
# (Ecosystem Guardian, Fase 7 / H6 — spec specs-ecosystem-guardian-20260802).
#
# REGRA DURA: NENHUMA sessao crua e deletada sem tatuagem confirmada no
# ledger do slot correspondente (<worktree>/.agent-guard/session-ledger/).
#
#   --dry-run  (PADRAO) lista o que seria apagado + total em MB/GB
#   --apply    apaga de fato e loga cada remocao em
#              ~/.kimi-code/session-cleanup.log
#
# Criterios para apagar (TODOS obrigatorios):
#   1. mtime da session dir > 30 dias (override: TATTOO_CLEANUP_DAYS)
#   2. existe linha com aquele session_id no ledger do worktree da sessao
#      (workDir resolvido via session_index.jsonl; fallback: nome wd_*)
#
# Cron semanal (domingo 04:23) — instalado comentado ate o merge do
# SPEC-ECOSYSTEM-GUARDIAN levar este arquivo ao repo principal:
#   23 4 * * 0 /home/hmvip-dev/hmvip/packages/agent-guard-core/session-tattoo/cleanup-sessions.sh --apply >> /home/hmvip-dev/.kimi-code/session-cleanup.log 2>&1
#
set -uo pipefail

MODE="dry-run"
[ "${1:-}" = "--apply" ] && MODE="apply"

SESSIONS_DIR="${TATTOO_SESSIONS_DIR:-${HOME}/.kimi-code/sessions}"
INDEX="${TATTOO_INDEX:-${HOME}/.kimi-code/session_index.jsonl}"
DAYS="${TATTOO_CLEANUP_DAYS:-30}"
LOG="${HOME}/.kimi-code/session-cleanup.log"

if [ ! -d "${SESSIONS_DIR}" ]; then
    echo "Nada a fazer: ${SESSIONS_DIR} nao existe."
    exit 0
fi

export CLEANUP_SESSIONS_DIR="${SESSIONS_DIR}" CLEANUP_INDEX="${INDEX}" \
       CLEANUP_DAYS="${DAYS}" CLEANUP_MODE="${MODE}" CLEANUP_LOG="${LOG}"

python3 <<'PY'
import glob, json, os, sys, time
from datetime import datetime, timezone

sessions_dir = os.environ["CLEANUP_SESSIONS_DIR"]
index_file   = os.environ["CLEANUP_INDEX"]
days         = int(os.environ["CLEANUP_DAYS"])
mode         = os.environ["CLEANUP_MODE"]
log_file     = os.environ["CLEANUP_LOG"]

cutoff = time.time() - days * 86400

# session_id -> workDir (indice oficial do Kimi)
workdir_of = {}
if os.path.isfile(index_file):
    try:
        with open(index_file) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if e.get("sessionId") and e.get("workDir"):
                    workdir_of[e["sessionId"]] = e["workDir"]
    except Exception:
        pass

def resolve_workdir(session_id, parent_name):
    wd = workdir_of.get(session_id)
    if wd:
        return wd
    # fallback: wd_<nome>_<hash> -> /home/hmvip-dev/<nome>
    if parent_name.startswith("wd_"):
        return "/home/hmvip-dev/" + parent_name[3:].rsplit("_", 1)[0]
    return None

def tattooed(session_id, workdir):
    if not workdir:
        return False
    pattern = os.path.join(workdir, ".agent-guard", "session-ledger", "*", "*.jsonl")
    for path in glob.glob(pattern):
        try:
            with open(path) as f:
                for line in f:
                    if session_id in line:
                        try:
                            if json.loads(line).get("session_id") == session_id:
                                return True
                        except Exception:
                            continue
        except Exception:
            continue
    return False

def dir_size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for fn in files:
            try:
                total += os.path.getsize(os.path.join(root, fn))
            except OSError:
                pass
    return total

candidates, skipped_no_tattoo, skipped_fresh = [], 0, 0
for parent in sorted(glob.glob(os.path.join(sessions_dir, "wd_*"))):
    if not os.path.isdir(parent):
        continue
    pname = os.path.basename(parent)
    for sdir in sorted(glob.glob(os.path.join(parent, "session_*"))):
        if not os.path.isdir(sdir):
            continue
        sid = os.path.basename(sdir)
        try:
            mtime = os.path.getmtime(sdir)
        except OSError:
            continue
        if mtime > cutoff:
            skipped_fresh += 1
            continue
        wd = resolve_workdir(sid, pname)
        if not tattooed(sid, wd):
            skipped_no_tattoo += 1
            continue
        candidates.append((sid, sdir, mtime, dir_size(sdir)))

total = sum(c[3] for c in candidates)
def human(n):
    return f"{n/1073741824:.2f} GB" if n >= 1073741824 else f"{n/1048576:.1f} MB"

print(f"Modo: {mode.upper()} | corte: >{days} dias | sessoes elegiveis: {len(candidates)} ({human(total)})")
print(f"Ignoradas: {skipped_fresh} recentes (<{days}d), {skipped_no_tattoo} SEM tatuagem no ledger (NUNCA apagadas)")

removed = 0
for sid, sdir, mtime, size in candidates:
    age = int((time.time() - mtime) / 86400)
    stamp = datetime.fromtimestamp(mtime, timezone.utc).strftime("%Y-%m-%d")
    if mode == "apply":
        import shutil
        try:
            shutil.rmtree(sdir)
            removed += 1
            line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] REMOVIDA {sid} ({human(size)}, mtime {stamp}, {age}d) {sdir}\n"
            print(f"  🗑  {sid}  {human(size):>9}  {age}d")
        except Exception as exc:
            line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] FALHA {sid}: {exc}\n"
            print(f"  ❌ {sid}: {exc}")
        try:
            with open(log_file, "a") as lf:
                lf.write(line)
        except Exception:
            pass
    else:
        print(f"  (dry-run) {sid}  {human(size):>9}  mtime {stamp} ({age}d)")

if mode == "apply":
    print(f"Removidas: {removed} sessoes, {human(sum(c[3] for c in candidates))} liberados — log em {log_file}")
else:
    print(f"Total que SERIA apagado com --apply: {human(total)}")
PY
