#!/usr/bin/env bash
# guard-decisions.sh — journal de decisões do guard (ADR-0064, spec H3).
#
# Append-only JSONL com UMA decisão por linha: bloqueios, liberações e
# verificações indeterminate ficam auditáveis depois que a aba do terminal
# morre.
#
# EXCEÇÃO CONTRATADA à regra de ouro tri-state: este módulo é OBSERVABILIDADE,
# não detector de segurança — por isso é fail-open (erro de escrita nunca
# bloqueia nem altera a decisão do guard). Detectores continuam em
# guard-semantics.sh com fail-closed estrito.
#
# Sourceado em shells de usuário: proibido set -e/set -u/trap/global sem AGS_.

AGS_DECISIONS_VERSION="1"

# Uso: ag_decision_log <identity> <worktree-basename> <decision> <predicate> <evidence>
# decision: allow | block | indeterminate
ag_decision_log() {
    local identity="$1" worktree_base="$2" decision="$3" predicate="$4" evidence="$5"
    local root file
    root="${AGENT_GUARD_REPO_ROOT:-}"
    if [ -z "$root" ]; then
        root="$(pwd)"
    fi
    file="${root}/.agent-guard/journal/guard-decisions.jsonl"

    AGS_LOG_IDENTITY="$identity" \
    AGS_LOG_WORKTREE="$worktree_base" \
    AGS_LOG_DECISION="$decision" \
    AGS_LOG_PREDICATE="$predicate" \
    AGS_LOG_EVIDENCE="$evidence" \
    AGS_LOG_SEMANTICS="${AGS_SEMANTICS_VERSION:-1}" \
    python3 - "$file" <<'PY' >>/dev/null 2>&1 || return 0
import json, os, sys, time

path = sys.argv[1]
record = {
    "ts_epoch": time.time(),
    "ts_mono": time.monotonic(),
    "identity": os.environ.get("AGS_LOG_IDENTITY", "")[:64],
    "worktree": os.environ.get("AGS_LOG_WORKTREE", "")[:128],
    "decision": os.environ.get("AGS_LOG_DECISION", "")[:32],
    "predicate": os.environ.get("AGS_LOG_PREDICATE", "")[:64],
    "evidence": os.environ.get("AGS_LOG_EVIDENCE", "")[:512],
    "semantics": os.environ.get("AGS_LOG_SEMANTICS", ""),
}
line = json.dumps(record, ensure_ascii=False)
os.makedirs(os.path.dirname(path), exist_ok=True)
# append exclusivo via flock (fd herdado do subshell python não aplica; usamos
# lockfile adjacente com timeout curto — falha de lock = drop silencioso)
lock = path + ".lock"
try:
    import fcntl
    with open(lock, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        fcntl.flock(lf, fcntl.LOCK_UN)
except Exception:
    sys.exit(0)
PY
    return 0
}

# Leitura: source agent-guard decisions --last N (implementado no bin).
ag_decisions_file() {
    local root="${AGENT_GUARD_REPO_ROOT:-$(pwd)}"
    printf '%s\n' "${root}/.agent-guard/journal/guard-decisions.jsonl"
}
