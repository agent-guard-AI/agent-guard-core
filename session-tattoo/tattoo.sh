#!/usr/bin/env bash
#
# tattoo.sh — gerador da "tatuagem de sessao" do Ecosystem Guardian (Fase 7,
# spec .kiro/specs/specs-ecosystem-guardian-20260802/ — H6, padrao entire.io
# nativo do agent-guard).
#
# Contrato: chamado pelos hooks do Kimi Code (mesmo padrao do kimi-tab-hook.sh)
#   tattoo.sh <evento>     # payload JSON do evento via stdin
#
# Eventos usados: stop (a cada turno) e session-end (fim da sessao).
#
# Gera/atualiza (UPSERT por session_id — nunca duplica) UMA linha JSONL em
#   <worktree>/.agent-guard/session-ledger/<slot>/<AAAA-MM>.jsonl
#
# REGRAS DURAS (spec H6):
#   - 1 linha/sessao, append-only, SEM conteudo de prompt/codigo — so metadados
#     (task_title = primeiros 80 chars do 1o prompt, titulo nao e conteudo).
#   - Campos indisponiveis ficam null — NUNCA falha por campo faltando.
#   - ENDURECER NUNCA LIMITAR: este script SEMPRE sai 0 — falha na tatuagem
#     jamais pode quebrar a sessao da IA.
#   - Rapido: roda no evento Stop (a cada turno) — alvo <3s.
#
# Env de override (testes):
#   TATTOO_SESSIONS_DIR  default ~/.kimi-code/sessions
#   TATTOO_INDEX         default ~/.kimi-code/session_index.jsonl
#   TATTOO_LEDGER_BASE   default = worktree da sessao (nao usar em producao)
#
set -u
umask 077

EVENT="${1:-stop}"

PAYLOAD=""
if [ ! -t 0 ]; then
    PAYLOAD="$(cat 2>/dev/null || true)"
fi

SESSIONS_DIR="${TATTOO_SESSIONS_DIR:-${HOME}/.kimi-code/sessions}"
INDEX="${TATTOO_INDEX:-${HOME}/.kimi-code/session_index.jsonl}"

# ---------------------------------------------------------------------------
# session_id e cwd do payload (tolerante; jq opcional).
# ---------------------------------------------------------------------------
_jq_get() {
    if [ -n "${PAYLOAD}" ] && command -v jq >/dev/null 2>&1; then
        printf '%s' "${PAYLOAD}" | jq -r "$1" 2>/dev/null || true
    fi
}

SESSION_ID="$(_jq_get '.session_id // .sessionId // empty')"
CWD="$(_jq_get '.cwd // empty')"
[ -z "${CWD}" ] && CWD="${PWD:-}"

# ---------------------------------------------------------------------------
# sessionDir/workDir via session_index.jsonl; fallback por glob e pelo nome
# do diretorio wd_<nome>_<hash>.
# ---------------------------------------------------------------------------
SESSION_DIR=""
WORK_DIR=""
if [ -n "${SESSION_ID}" ] && [ -f "${INDEX}" ] && command -v python3 >/dev/null 2>&1; then
    eval "$(python3 - "${INDEX}" "${SESSION_ID}" <<'PY' 2>/dev/null || true
import json, sys, shlex
index, sid = sys.argv[1], sys.argv[2]
try:
    with open(index) as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("sessionId") == sid:
                print("SESSION_DIR=" + shlex.quote(e.get("sessionDir") or ""))
                print("WORK_DIR=" + shlex.quote(e.get("workDir") or ""))
                break
except Exception:
    pass
PY
)"
fi

if [ -z "${SESSION_DIR}" ] && [ -n "${SESSION_ID}" ] && [ -d "${SESSIONS_DIR}" ]; then
    for d in "${SESSIONS_DIR}"/*/"${SESSION_ID}"; do
        [ -d "${d}" ] && SESSION_DIR="${d}" && break
    done
fi

if [ -z "${WORK_DIR}" ] && [ -n "${SESSION_DIR}" ]; then
    base="$(basename "$(dirname "${SESSION_DIR}")")"
    case "${base}" in
        wd_*_*) WORK_DIR="/home/hmvip-dev/${base#wd_}"; WORK_DIR="${WORK_DIR%_*}" ;;
    esac
fi
[ -z "${WORK_DIR}" ] && WORK_DIR="${CWD}"

# Sem session_id e sem session dir nao ha o que tatuar — sai em silencio.
if [ -z "${SESSION_ID}" ] && [ -z "${SESSION_DIR}" ]; then
    exit 0
fi
if [ -z "${SESSION_ID}" ] && [ -n "${SESSION_DIR}" ]; then
    SESSION_ID="$(basename "${SESSION_DIR}")"
fi
if [ -z "${SESSION_DIR}" ] || [ ! -d "${SESSION_DIR}" ]; then
    SESSION_DIR=""
fi

# ---------------------------------------------------------------------------
# Slot e ledger.
# ---------------------------------------------------------------------------
wt_base="$(basename "${WORK_DIR}" 2>/dev/null || echo "${WORK_DIR}")"
case "${wt_base}" in
    hmvip-ia-*) SLOT="${wt_base#hmvip-ia-}" ;;
    *)          SLOT="${wt_base}" ;;
esac

LEDGER_BASE="${TATTOO_LEDGER_BASE:-${WORK_DIR}}"
LEDGER_DIR="${LEDGER_BASE}/.agent-guard/session-ledger/${SLOT}"
LEDGER_FILE="${LEDGER_DIR}/$(date -u +%Y-%m).jsonl"

# So tatua se o worktree existir e for gravavel; caso contrario, silencio.
if [ ! -d "${LEDGER_BASE}" ]; then
    exit 0
fi
mkdir -p "${LEDGER_DIR}" 2>/dev/null || exit 0
[ -w "${LEDGER_DIR}" ] || exit 0

export TATTOO_EVENT="${EVENT}" TATTOO_SESSION_ID="${SESSION_ID}" \
       TATTOO_SESSION_DIR="${SESSION_DIR}" TATTOO_WORK_DIR="${WORK_DIR}" \
       TATTOO_SLOT="${SLOT}" TATTOO_LEDGER_FILE="${LEDGER_FILE}"

python3 <<'PY' 2>/dev/null || true
import json, os, re, subprocess, sys, fcntl, tempfile
from datetime import datetime, timezone

event       = os.environ["TATTOO_EVENT"]
session_id  = os.environ["TATTOO_SESSION_ID"]
session_dir = os.environ["TATTOO_SESSION_DIR"]
work_dir    = os.environ["TATTOO_WORK_DIR"]
slot        = os.environ["TATTOO_SLOT"]
ledger_file = os.environ["TATTOO_LEDGER_FILE"]

now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def iso_from_ms(ms):
    try:
        return datetime.fromtimestamp(int(ms) / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return None

wire = os.path.join(session_dir, "agents", "main", "wire.jsonl") if session_dir else ""
statef = os.path.join(session_dir, "state.json") if session_dir else ""

# --- started_at: state.json createdAt -> metadata created_at (ms) -> None ---
started_at = None
if statef and os.path.isfile(statef):
    try:
        with open(statef) as f:
            started_at = json.load(f).get("createdAt") or None
    except Exception:
        pass

# --- wire.jsonl: 1o prompt do usuario (early exit) + started_at metadata ---
task_title = None
wire_compactions = 0
if wire and os.path.isfile(wire):
    try:
        with open(wire, "rb") as f:
            for raw in f:
                # contagem barata de compactacoes sem parsear a linha inteira
                if b"full_compaction.complete" in raw:
                    wire_compactions += 1
                if started_at is not None and task_title is not None:
                    continue  # ainda contamos compactacoes, mas sem json.loads
                try:
                    e = json.loads(raw)
                except Exception:
                    continue
                t = e.get("type")
                if started_at is None and t == "metadata" and e.get("created_at"):
                    started_at = iso_from_ms(e.get("created_at"))
                if task_title is None and t == "context.append_message":
                    m = e.get("message") or {}
                    if m.get("role") == "user" and (m.get("origin") or {}).get("kind") == "user":
                        parts = m.get("content") or []
                        text = ""
                        if isinstance(parts, list):
                            for p in parts:
                                if isinstance(p, dict) and p.get("type") == "text":
                                    text = p.get("text") or ""
                                    break
                        elif isinstance(parts, str):
                            text = parts
                        text = re.sub(r"\s+", " ", text).strip()
                        # Descarta moldura de prompt renderizado ("Prompt: │ ...").
                        text = re.sub(r"^(Prompt:)?\s*[│| ]*", "", text).strip()
                        if text:
                            task_title = text[:80]
    except Exception:
        pass

# --- compactions: arquivos context_*.jsonl (spec) com fallback no wire ---
compactions = 0
if session_dir:
    for root, _dirs, files in os.walk(session_dir):
        for fn in files:
            if fn.startswith("context_") and fn.endswith(".jsonl"):
                compactions += 1
if compactions == 0:
    compactions = wire_compactions

# --- git: branch, commits desde o inicio da sessao, arquivos, sensitive ---
def git(*args, timeout=2):
    try:
        r = subprocess.run(["git", "-C", work_dir] + list(args),
                           capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else ""
    except Exception:
        return ""

branch = None
commits = []
files_touched = None
sensitive = []

if os.path.isdir(work_dir):
    b = git("branch", "--show-current").strip()
    branch = b or None
    log_args = ["log", "--format=%H", "-n", "50", "HEAD"]
    if started_at:
        log_args = ["log", "--format=%H", "--since=" + started_at, "-n", "50", "HEAD"]
    out = git(*log_args)
    commits = [l.strip() for l in out.splitlines() if l.strip()]
    if commits:
        names = git("log", "--format=", "--name-only", "-n", "50", "HEAD",
                    *(["--since=" + started_at] if started_at else []))
        files_touched = len({l.strip() for l in names.splitlines() if l.strip()})
        cats = set()
        for sha in commits[:10]:
            note = git("notes", "--ref=hmvip-worktree", "show", sha)
            for line in note.splitlines():
                if line.startswith("sensitive:"):
                    for c in line.split(":", 1)[1].split(","):
                        c = c.strip()
                        if c:
                            cats.add(c)
        sensitive = sorted(cats)

# --- outcome: session-end => released; demais preservam o existente ---
prev_outcome = None
existing_lines = []
if os.path.isfile(ledger_file):
    try:
        with open(ledger_file) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line.strip():
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    existing_lines.append(line)
                    continue
                if e.get("session_id") == session_id:
                    prev_outcome = e.get("outcome")
                    if task_title is None:
                        task_title = e.get("task_title")
                    if started_at is None:
                        started_at = e.get("started_at")
                    if branch is None:
                        branch = e.get("branch")
                    continue  # upsert: descarta a linha antiga desta sessao
                existing_lines.append(line)
    except Exception:
        pass

# --- outcome: session-end => released; qualquer Stop posterior => open ---
# (um Stop prova que a sessao esta viva — nao preserva released estagnado).
outcome = "released" if event in ("session-end", "session_end", "release") else "open"

tattoo = {
    "session_id": session_id,
    "slot": slot,
    "worktree": work_dir,
    "started_at": started_at,
    "last_stop": now_iso,
    "branch": branch,
    "task_title": task_title,
    "compactions": compactions,
    "commits": commits,
    "prs": None,  # sem chamada gh no hook (orcamento <3s); cruze via git notes/CLI
    "files_touched": files_touched,
    "sensitive": sensitive,
    "outcome": outcome,
}

# --- upsert atomico com lock ---
lock_path = ledger_file + ".lock"
try:
    with open(lock_path, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        existing_lines.append(json.dumps(tattoo, ensure_ascii=False, separators=(",", ":")))
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(ledger_file), prefix=".tattoo-")
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(existing_lines) + "\n")
        os.replace(tmp, ledger_file)
except Exception:
    try:
        os.unlink(tmp)  # noqa: F821
    except Exception:
        pass
PY

exit 0
