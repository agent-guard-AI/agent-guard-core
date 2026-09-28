#!/usr/bin/env bash
# guard-semantics.sh — predicados canônicos tri-state do control plane (ADR-0064).
#
# Consumido por src/init.sh e pelos 5 wrappers (kiro/kimi/kilo/amp/codewhale).
# É SOURCEADO em shells de usuário: proibido set -e/set -u/trap/global sem
# prefixo AGS_ (incidente L220 — shell-isolation-test.sh deve permanecer verde).
#
# CONTRATO TRI-STATE (regra de ouro: indeterminate NUNCA vira ok):
#   exit 0 = ok        (condição segura: clean, dirty_residue, claimable)
#   exit 1 = violation (condição insegura: dirty_work, mid_operation,
#                      worktree_missing, held)
#   exit 2 = indeterminate (NÃO FOI POSSÍVEL VERIFICAR — consumidor fail-closed)
#
# Stdout: primeira linha = estado; demais linhas = evidência (paths/motivos).

AGS_SEMANTICS_VERSION="2"

ag_semantics_version() {
    printf '%s\n' "${AGS_SEMANTICS_VERSION}"
}

# boot_id atual da máquina (vazio se indisponível).
ags_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf ''
}

# starttime (campo 22 de /proc/<pid>/stat) — imune a PID recycling. Vazio se
# o processo não existir ou /proc estiver indisponível.
ags_pid_starttime() {
    local pid="$1"
    [ -z "$pid" ] && return 1
    awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || printf ''
}

# Staleness com relógio monotonic (imune a NTP step, C6).
# Uso: ags_session_stale <session-file> <threshold-seconds>
# exit 0 = stale | 1 = não-stale | 2 = indeterminate (arquivo ilegível —
# consumidor DEVE tratar como não-stale para não liberar slot ativo por
# storage quebrado: fail-safe contra cleanup errado).
ags_session_stale() {
    local session_file="$1" threshold="${2:-86400}" out rc
    if [ -z "$session_file" ] || [ ! -e "$session_file" ]; then
        return 1
    fi
    out="$(python3 - "$session_file" "$threshold" <<'PY' 2>/dev/null
import json, sys, time
path, threshold = sys.argv[1], float(sys.argv[2])
try:
    with open(path, encoding='utf-8', errors='replace') as fh:
        d = json.load(fh)
except Exception:
    print("indeterminate")
    sys.exit(0)
if d.get('status') != 'active':
    print("not-stale")
    sys.exit(0)
boot = None
try:
    with open('/proc/sys/kernel/random/boot_id') as fh:
        boot = fh.read().strip()
except Exception:
    pass
mono = d.get('last_activity_mono')
aboot = d.get('activity_boot_id')
if mono is not None and aboot and aboot == boot:
    age = time.monotonic() - float(mono)
    print("stale" if age > threshold else "not-stale")
    sys.exit(0)
# Degrau de confiança (leases legados sem par mono/boot): epoch de parede.
la = d.get('last_activity') or d.get('timestamp')
if not la:
    print("not-stale")
    sys.exit(0)
try:
    age = time.time() - float(la)
except Exception:
    print("not-stale")
    sys.exit(0)
print("stale" if age > threshold else "not-stale")
PY
)"
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        return 1
    fi
    case "$out" in
        stale) return 0 ;;
        indeterminate) return 2 ;;
        *) return 1 ;;
    esac
}

# Lista canônica de resíduo operacional do agent-guard (paths relativos à raiz
# do worktree). UM único ponto de definição — drift entre consumidores é
# impossível por construção (foi o que gerou o bug do slot-note, #8155).
ag_operational_residue() {
    local identity="$1"
    if [ -z "$identity" ]; then
        return 2
    fi
    printf '.agent-guard/tasks/%s.md\n' "$identity"
    printf '.agent-guard/journal\n'
    printf '.agent-guard/session\n'
}

# Roda git com retry (backoff 0.2s/1s/5s) quando rc != 0.
# Retorna rc final; stdout = output da última tentativa.
_ags_git() {
    local attempt=1 rc=1 out=""
    while [ "$attempt" -le 4 ]; do
        out="$(git "$@" 2>/dev/null)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '%s' "$out"
            return 0
        fi
        if [ "$attempt" -eq 4 ]; then
            break
        fi
        case "$attempt" in
            1) sleep 0.2 ;;
            2) sleep 1 ;;
            3) sleep 5 ;;
        esac
        attempt=$((attempt + 1))
    done
    return "$rc"
}

# path casa com resíduo: arquivo exato, conteúdo de diretório de resíduo,
# ou diretório de resíduo listado como untracked (com barra).
_ags_path_is_residue() {
    local path="$1" residues="$2" r
    case "$path" in
        \"*\") path="${path#\"}"; path="${path%\"}" ;;
    esac
    [ -z "$residues" ] && return 1
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        if [ "$path" = "$r" ] \
            || [ "${path#"$r"/}" != "$path" ] \
            || [ "${r#"$path"/}" != "$r" ]; then
            return 0
        fi
    done <<EOF
$residues
EOF
    return 1
}

# ---------------------------------------------------------------------------
# Guard-home health check (Wave E, ADR-0064, H2). O wrapper opera com o
# guard-home (repo principal); se ele estiver em branch arbitrária, com
# operação Git transacional ou yaml incompatível, o wrapper tomaria decisões
# com config/código errados — e o fail-open legado abria SEM isolamento.
# Uso: ags_guard_home_state <repo-root> [ref-esperada]
# exit 0 = ok | 1 = violation (stdout = motivo) | 2 = indeterminate
# Ref esperada: env AG_GUARD_HOME_REF (default "develop").
ags_guard_home_state() {
    local repo_root="$1" expected_ref="${2:-${AG_GUARD_HOME_REF:-develop}}"
    local gitdir head
    if [ -z "$repo_root" ] || [ ! -d "$repo_root" ]; then
        printf 'missing-repo\n'
        return 2
    fi
    if ! _ags_git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null; then
        printf 'git-unreachable\n'
        return 2
    fi
    gitdir="$(_ags_git -C "$repo_root" rev-parse --absolute-git-dir)"
    if [ -z "$gitdir" ]; then
        printf 'gitdir-unreachable\n'
        return 2
    fi
    head="$(_ags_git -C "$repo_root" branch --show-current)"
    head="${head%%$'\n'*}"
    if [ -z "$head" ]; then
        printf 'detached-head\n'
        return 1
    fi
    if [ -n "$expected_ref" ] && [ "$head" != "$expected_ref" ]; then
        printf 'wrong-ref %s (expected %s)\n' "$head" "$expected_ref"
        return 1
    fi
    local op
    for op in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD sequencer; do
        if [ -e "$gitdir/$op" ]; then
            printf 'mid-operation %s\n' "$op"
            return 1
        fi
    done
    if ! grep -q '^schema: agent-guard-v1' "$repo_root/agent-guard.yaml" 2>/dev/null; then
        printf 'bad-yaml-schema\n'
        return 1
    fi
    printf 'ok\n'
    return 0
}

# Classificador de órfão funcionalmente morto (Wave D, ADR-0064, C7).
#
# Um processo pode estar VIVO mas funcionalmente morto: sobreviveu ao
# fechamento do terminal (desanexado), não tem sessão ativa, zero atividade.
# O predicado binário vivo/morto não distingue isso e o slot fica preso por
# até stale_threshold. TRÊS sinais independentes, nunca kill:
#   1. heartbeat ausente há ≥ grace (epoch/mono do session)
#   2. sem TTY (processo desanexado)
#   3. ΔCPU ≈ 0 entre duas amostras de /proc/<pid>/stat
#
# Uso: ags_orphan_state <session-file> [grace-minutes]
# exit 0 = active (não órfão) | 1 = functionally_dead | 2 = indeterminate
# PID morto → exit 0 (não é caso de órfão; o caminho claimable normal trata).
# ---------------------------------------------------------------------------
ags_orphan_state() {
    local session_file="$1" grace_min="${2:-30}"
    local parsed status pid
    if [ -z "$session_file" ] || [ ! -e "$session_file" ]; then
        return 2
    fi
    parsed="$(python3 - "$session_file" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8', errors='replace') as fh:
        d = json.load(fh)
    print(f"{d.get('status','')}\t{d.get('pid') or ''}\t{d.get('last_activity') or ''}")
except Exception:
    sys.exit(1)
PY
)"
    if [ -z "$parsed" ]; then
        return 2
    fi
    status="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    pid="${parsed%%$'\t'*}"
    local last_activity="${parsed#*$'\t'}"
    if [ "$status" != "active" ] || [ -z "$pid" ]; then
        return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    local proc_state
    proc_state="$(sed -n 's/.*) \([A-Za-z]\).*/\1/p' "/proc/${pid}/stat" 2>/dev/null || printf '')"
    case "$proc_state" in
        T|Z|X|x) return 0 ;;  # parado/zumbi: não é órfão funcional
    esac

    # Sinal 1: heartbeat ausente há ≥ grace minutos
    local s1=0
    if [ -n "$last_activity" ]; then
        local idle
        idle="$(python3 - "$last_activity" "$grace_min" <<'PY' 2>/dev/null
import sys, time
try:
    la = float(sys.argv[1]); grace = float(sys.argv[2]) * 60.0
    print("stale" if (time.time() - la) >= grace else "fresh")
except Exception:
    print("unknown")
PY
)"
        [ "$idle" = "stale" ] && s1=1
    else
        s1=1  # sem heartbeat registrado: sinal suspeito
    fi

    # Sinal 2: sem TTY (ps -o tty= → '?')
    local s2=0 tty
    tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ' || printf '?')"
    [ "$tty" = "?" ] && s2=1

    # Sinal 3: ΔCPU ≈ 0 (utime+stime idênticos entre duas amostras)
    local s3=0 c1 c2
    c1="$(awk '{print $14+$15}' "/proc/${pid}/stat" 2>/dev/null || printf '')"
    sleep 0.3
    c2="$(awk '{print $14+$15}' "/proc/${pid}/stat" 2>/dev/null || printf '')"
    if [ -n "$c1" ] && [ -n "$c2" ] && [ "$c1" = "$c2" ]; then
        s3=1
    fi

    if [ "$s1" -eq 1 ] && [ "$s2" -eq 1 ] && [ "$s3" -eq 1 ]; then
        return 1  # functionally_dead
    fi
    return 0
}

# Predicado principal: estado do worktree para receber uma sessão.
# Uso: ag_worktree_state <worktree> <identity>
ag_worktree_state() {
    local worktree="$1" identity="${2:-}"
    local gitdir op status_out residues line path
    local saw_any="" saw_residue="" rest=""

    if [ -z "$worktree" ]; then
        printf 'indeterminate\nmissing-argument worktree\n'
        return 2
    fi
    if [ ! -d "$worktree" ]; then
        printf 'violation\nworktree_missing %s\n' "$worktree"
        return 1
    fi

    # 1) saúde do repositório git (fail-closed: não verificável = indeterminate)
    if ! _ags_git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null; then
        printf 'indeterminate\ngit_unreachable %s\n' "$worktree"
        return 2
    fi

    # 2) operação Git transacional em andamento (fail-closed)
    gitdir="$(_ags_git -C "$worktree" rev-parse --absolute-git-dir)"
    if [ -z "$gitdir" ]; then
        printf 'indeterminate\ngitdir_unreachable %s\n' "$worktree"
        return 2
    fi
    for op in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD sequencer; do
        if [ -e "$gitdir/$op" ]; then
            printf 'violation\nmid_operation %s\n' "$op"
            return 1
        fi
    done

    # 3) árvore de trabalho: sujeira real vs resíduo operacional
    status_out="$(_ags_git -C "$worktree" status --porcelain=v1)"
    if [ -z "$status_out" ]; then
        printf 'clean\n'
        return 0
    fi

    residues="$(ag_operational_residue "$identity")" || residues=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        saw_any=1
        path="${line#???}"
        if _ags_path_is_residue "$path" "$residues"; then
            saw_residue=1
        else
            rest="${rest}${path}
"
        fi
    done <<EOF
$status_out
EOF

    if [ -n "$rest" ]; then
        printf 'dirty_work\n%b' "$rest"
        return 1
    fi
    if [ -n "$saw_any" ]; then
        printf 'dirty_residue\n'
        return 0
    fi
    printf 'clean\n'
    return 0
}

# Predicado preliminar de lease (Wave A; Wave B endurece com starttime/boot_id).
# Uso: ag_lease_claimable <session-file.json>
# exit 0 = claimable | 1 = held | 2 = indeterminate
ag_lease_claimable() {
    local session_file="$1" parsed status pid proc_state
    if [ -z "$session_file" ]; then
        printf 'indeterminate\nmissing-argument session-file\n'
        return 2
    fi
    if [ ! -e "$session_file" ]; then
        printf 'claimable\nno-session-file\n'
        return 0
    fi
    parsed="$(python3 - "$session_file" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8', errors='replace') as fh:
        data = json.load(fh)
    status = data.get('status') or data.get('session', {}).get('status') or ''
    pid = data.get('pid') or data.get('session', {}).get('pid') or ''
    st = data.get('pid_starttime')
    boot = data.get('boot_id')
    print(f"{status}\t{pid}\t{st if st is not None else ''}\t{boot or ''}")
except Exception:
    sys.exit(1)
PY
)"
    if [ -z "$parsed" ]; then
        printf 'indeterminate\nsession-unreadable %s\n' "$session_file"
        return 2
    fi
    status="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    pid="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    local sess_starttime="${parsed%%$'\t'*}" sess_boot="${parsed#*$'\t'}"

    if [ "$status" != "active" ] || [ -z "$pid" ]; then
        printf 'claimable\nstatus-%s\n' "${status:-unknown}"
        return 0
    fi

    # Lease identity (Wave B): boot_id divergente = reboot = morto por construção.
    if [ -n "$sess_boot" ]; then
        local cur_boot
        cur_boot="$(ags_boot_id)"
        if [ -n "$cur_boot" ] && [ "$sess_boot" != "$cur_boot" ]; then
            printf 'claimable\nreboot-boot-mismatch\n'
            return 0
        fi
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        printf 'claimable\ndead-pid-%s\n' "$pid"
        return 0
    fi
    proc_state="$(sed -n 's/.*) \([A-Za-z]\).*/\1/p' "/proc/${pid}/stat" 2>/dev/null || printf '')"
    case "$proc_state" in
        T|Z|X|x)
            printf 'claimable\nproc-state-%s\n' "$proc_state"
            return 0
            ;;
    esac

    # starttime divergente = PID reciclado pelo kernel = morto.
    if [ -n "$sess_starttime" ]; then
        local cur_starttime
        cur_starttime="$(ags_pid_starttime "$pid")"
        if [ -n "$cur_starttime" ] && [ "$sess_starttime" != "$cur_starttime" ]; then
            printf 'claimable\npid-recycled\n'
            return 0
        fi
    fi

    printf 'held\npid-%s\n' "$pid"
    return 1
}
