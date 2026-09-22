#!/usr/bin/env bash
#
# agent-guard-core — F0-F S2: CLAIM lifecycle na control plane (v2)
#
# Separação de estado (revisão independente #7603):
# - DURÁVEL (Git): claim.md, execution-log.md, evidence/, .released do RUN
#   vivem no WORKTREE do claimant (`.kiro/runs/<task_id>/<run_seq>/`), na
#   branch dele — realmente commitáveis por ele.
# - COMPARTILHADO/TRANSITÓRIO (exclusividade): lock por task em
#   `<main_repo>/.kiro/locks/claims/<task_id>.d/<run_seq>.lock` — coordenação
#   apenas, NÃO finge ser o claim.md canônico. Reutiliza a resolução por
#   git-common-dir do session storage do Agent Guard.
#
# Exclusividade: um TASK, um claimant ativo por vez.
# - Aquisição atômica: mutex flock (mesmo idiom do journal.sh/init.sh) +
#   scan + create dentro da seção crítica. Duas claims concorrentes:
#   exatamente uma vence; a outra falha sem sobrescrever nada.
# - Lock de slot sem lease ativa no worktree do lock é stale e pode ser
#   tomado (journal). O stale-take grava stale-supersedes no run dir do
#   TOMADOR (nunca no worktree alheio) — ver regra de atividade durável.
# - Atividade DURÁVEL (reconstrução por Git, sem lock/journal): um run é
#   ativo iff claim.md existe, não tem .released e nenhum run POSTERIOR do
#   mesmo TASK o declara em stale-supersedes. Invariante: exatamente 1 ativo.
# - run_seq é GLOBAL por TASK: escolhido dentro do mutex compartilhado com
#   base nos runs de todos os linked worktrees (Git é SSOT) + registro
#   transitório .seq-registry no lock dir (append-only — seq nunca reutilizado).
#
# Lease (fail-closed): claim exige identidade Agent Guard válida (prefixo em
# agent-guard.yaml), session ativa para o slot e worktree_path == worktree
# corrente. AGENT_GUARD_CLAIM_IDENTITY é seam hermético de teste (mesmo
# padrão de AGENT_GUARD_PR_PROVIDER) — a validação de lease SEMPRE roda.
#
# Uso (sourced, via bin/agent-guard):
#   source agent-guard claim <task_id> [--run-seq NN] [--branch B]
#                            [--confidence alta|media|baixa] [--plan-file P]
#   source agent-guard claim --status <task_id>
#   source agent-guard claim --check <task_id>
#   source agent-guard claim --release <task_id> [--run-seq NN]

# Guard against double-sourcing.
if [[ -n "${_CLAIM_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAIM_SH_LOADED=1

set -euo pipefail

_CLAIM_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# claim.sh depende do task lifecycle (frontmatter, notas de slot).
if [[ -z "${_TASK_LIFECYCLE_LOADED:-}" ]]; then
    # shellcheck source=/dev/null
    source "${_CLAIM_CORE_DIR}/src/task-lifecycle.sh"
fi

# ---------------------------------------------------------------------------
# Resolução de caminhos
# ---------------------------------------------------------------------------

# Repo principal (compartilhado entre linked worktrees) via git-common-dir —
# mesma resolução de _get_session_file() do init.sh.
_claim_main_repo() {
    local git_common_dir
    git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "${git_common_dir}" = /* ]]; then
        cd "$(dirname "${git_common_dir}")" && pwd
    else
        cd "$(dirname "${git_common_dir}")" && pwd
    fi
}

# Diretório de session storage (lease). Hermeticidade: o override
# AGENT_GUARD_CLAIM_SESSION_DIR espelha o padrão AGENT_GUARD_PR_PROVIDER —
# serve para testes; em operação real nunca está definido e a config
# paths.session_storage (agent-guard.yaml) é a fonte.
_claim_session_dir() {
    local main_repo="${1:-}"
    if [[ -n "${AGENT_GUARD_CLAIM_SESSION_DIR:-}" ]]; then
        echo "${AGENT_GUARD_CLAIM_SESSION_DIR}"
        return 0
    fi
    local storage
    storage="$(AGENT_GUARD_REPO_ROOT="${AGENT_GUARD_REPO_ROOT:-$(pwd)}" bash "${_CLAIM_CORE_DIR}/bin/agent-guard-config" get paths.session_storage "" 2>/dev/null || true)"
    storage="${storage:-.agent-guard/sessions}"
    echo "${main_repo}/${storage}"
}

# Diretório de coordenação de claims (compartilhado, transitório).
_claim_claims_root() {
    local main_repo="${1:-}"
    local session_dir
    session_dir="$(_claim_session_dir "${main_repo}")"
    if [[ "${session_dir}" = /* && -n "${AGENT_GUARD_CLAIM_SESSION_DIR:-}" ]]; then
        # Override hermético: claims ficam ao lado do session dir injetado.
        echo "${session_dir}/claims"
        return 0
    fi
    echo "$(dirname "${session_dir}")/claims"
}

_claim_task_lock_dir() {
    local main_repo="${1:-}"
    local task_id="${2:-}"
    echo "$(_claim_claims_root "${main_repo}")/${task_id}.d"
}

# Worktree corrente (onde o RUN durável nasce).
_claim_worktree_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# ---------------------------------------------------------------------------
# Identidade e lease
# ---------------------------------------------------------------------------

# Identidade do slot a partir do worktree (mesma regra do task-cli), com
# override hermético AGENT_GUARD_CLAIM_IDENTITY para testes.
_claim_current_identity() {
    if [[ -n "${AGENT_GUARD_CLAIM_IDENTITY:-}" ]]; then
        echo "${AGENT_GUARD_CLAIM_IDENTITY}"
        return 0
    fi
    local worktree
    worktree="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    local git_email
    git_email="$(git -C "${worktree}" config --worktree user.email 2>/dev/null || git -C "${worktree}" config user.email 2>/dev/null || echo "")"
    if [[ "${git_email}" =~ ^agent-([a-z]+[0-9]+)@ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    basename "${worktree}" | sed 's/^hmvip-ia-//'
}

# Valida identidade + lease. FAIL-CLOSED em qualquer inconsistência.
# Uso: _claim_verify_lease <identity> <worktree> <session_dir>
_claim_verify_lease() {
    local identity="${1:-}"
    local worktree="${2:-}"
    local session_dir="${3:-}"

    # 1) Identidade conhecida pelo agent-guard.yaml.
    local known
    known="$(AGENT_GUARD_REPO_ROOT="${AGENT_GUARD_REPO_ROOT:-$(pwd)}" bash "${_CLAIM_CORE_DIR}/bin/agent-guard-config" keys identities 2>/dev/null || true)"
    if [[ -z "${known}" ]]; then
        echo "❌ agent-guard.yaml indisponível — não foi possível validar a identidade '${identity}'. Fail-closed." >&2
        return 1
    fi
    local prefix="${identity%%[0-9]*}"
    if [[ ! " ${known} " =~ \ ${prefix}\  ]]; then
        echo "❌ Identidade '${identity}' não é um slot Agent Guard válido (prefixos: ${known})." >&2
        return 1
    fi

    # 2) Session/lease existe e está ativa, pertencendo a ESTE worktree.
    local session_file="${session_dir}/${identity}.json"
    if [[ ! -f "${session_file}" ]]; then
        echo "❌ Sem lease ativa: session file ausente para '${identity}' (${session_file})." >&2
        echo "   Rode 'source .hmvip-agent-init <prefix> <papel>' antes de claim. Fail-closed." >&2
        return 1
    fi

    local status wt_path
    status="$("${AG_PYTHON}" -c "import json;print(json.load(open('${session_file}')).get('status',''))" 2>/dev/null || true)"
    if [[ "${status}" != "active" ]]; then
        echo "❌ Lease de '${identity}' não está ativa (status='${status}'). Fail-closed." >&2
        return 1
    fi
    wt_path="$("${AG_PYTHON}" -c "import json;print(json.load(open('${session_file}')).get('worktree_path',''))" 2>/dev/null || true)"
    if [[ "${wt_path}" != "${worktree}" ]]; then
        echo "❌ Lease de '${identity}' pertence a outro worktree ('${wt_path}'), não a '${worktree}'. Fail-closed." >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Scan de locks ativos (fail-closed, sem vazar shopt)
# ---------------------------------------------------------------------------

# Preenche _CLAIM_ACTIVE_LOCKS=("<seq>:<slot>:<worktree>" ...) para o TASK.
# rc: 0 ok (0 ou 1 ativo) | 2 CORRUPT (>1 ativo ou slot vazio).
# Nunca vaza nullglob: captura o glob em array antes de qualquer return.
_claim_scan_active_locks() {
    _CLAIM_ACTIVE_LOCKS=()
    local lock_dir="${1:-}"
    [[ -d "${lock_dir}" ]] || return 0

    local nullglob_was_off=1
    shopt -q nullglob && nullglob_was_off=0
    shopt -s nullglob
    local files=("${lock_dir}"/*.lock)
    if (( nullglob_was_off )); then shopt -u nullglob; else shopt -s nullglob; fi

    local f seq slot wt
    for f in "${files[@]}"; do
        [[ -f "${f}" ]] || continue
        seq="$(basename "${f}" .lock)"
        slot="$(sed -n 's/^slot=//p' "${f}" | head -n1)"
        wt="$(sed -n 's/^worktree=//p' "${f}" | head -n1)"
        if [[ -z "${slot}" ]]; then
            echo "❌ Lock corrompido (slot vazio): ${f}" >&2
            return 2
        fi
        _CLAIM_ACTIVE_LOCKS+=("${seq}:${slot}:${wt}")
    done

    if [[ ${#_CLAIM_ACTIVE_LOCKS[@]} -gt 1 ]]; then
        echo "❌ CORRUPT: ${#_CLAIM_ACTIVE_LOCKS[@]} claims ativos em ${lock_dir}." >&2
        echo "   Fail-closed — ESCALATION ao owner." >&2
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Mutex (flock não-bloqueante com retry limitado — mesmo idiom do init.sh)
# ---------------------------------------------------------------------------

_claim_with_mutex() {
    local main_repo="${1:-}"
    shift
    local claims_root
    claims_root="$(_claim_claims_root "${main_repo}")"
    mkdir -p "${claims_root}"
    local mutex="${claims_root}/.mutex"
    touch "${mutex}"

    local lock_fd=211
    eval "exec ${lock_fd}>\"${mutex}\""
    local attempt=0
    while ! flock -n -x "${lock_fd}" 2>/dev/null; do
        attempt=$((attempt + 1))
        if [[ "${attempt}" -ge 25 ]]; then
            echo "❌ Não foi possível obter o mutex de claims (5s). Tente novamente." >&2
            eval "exec ${lock_fd}>&-" 2>/dev/null || true
            return 1
        fi
        sleep 0.2
    done

    local rc=0
    "$@" || rc=$?
    flock -u "${lock_fd}" 2>/dev/null || true
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
    return "${rc}"
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Run ativo por TASK — regra durável canônica S2 (F0-F). Um run é ativo iff:
#   claim.md existe  AND  sem .released  AND  nenhum run POSTERIOR do mesmo
#   TASK (comparação NUMÉRICA de run_seq) o declara em stale-supersedes.
# Escaneia todos os linked worktrees (runs podem existir em worktree alheio
# pós-reclaim/stale-take). Único ponto canônico da regra — o VERIFICATION
# register (S3) e demais consumidores reutilizam, nunca duplicam.
#
# Uso: _claim_active_run_dir <task_id>
# Saída (última linha): <run_dir> do run ativo.
# rc: 0 = exatamente 1 ativo | 1 = nenhum ativo | 2 = CORRUPT (>1 ativo).
_claim_active_run_dir() {
    local task_id="${1:-}"
    [[ -n "${task_id}" ]] || return 1

    local -a roots=()
    local wt
    while IFS= read -r wt; do
        [[ -n "${wt}" ]] && roots+=("${wt}")
    done < <(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
    local cur
    cur="$(_claim_worktree_root)"
    [[ -n "${cur}" ]] && roots+=("${cur}")
    # dedup
    local -a uniq=()
    local r
    for r in "${roots[@]:-}"; do
        [[ -z "${r}" ]] && continue
        [[ " ${uniq[*]:-} " == *" ${r} "* ]] && continue
        uniq+=("${r}")
    done

    # historical_runs: TODOS os runs com claim.md (inclusive released).
    local -a hist=()
    local base rd seq
    local nullglob_was_off=1
    shopt -q nullglob && nullglob_was_off=0
    for r in "${uniq[@]:-}"; do
        base="${r}/.kiro/runs/${task_id}"
        [[ -d "${base}" ]] || continue
        shopt -s nullglob
        local rds=("${base}"/*/)
        if (( nullglob_was_off )); then shopt -u nullglob; else shopt -s nullglob; fi
        for rd in "${rds[@]:-}"; do
            rd="${rd%/}"
            [[ -f "${rd}/claim.md" ]] || continue
            seq="$(basename "${rd}")"
            [[ "${seq}" =~ ^[0-9]+$ ]] || continue
            hist+=("${seq}|${rd}")
        done
    done

    # active_candidates: sem .released E não declarado em stale-supersedes de
    # run POSTERIOR. CRÍTICO: a supersession consulta TODOS os runs
    # históricos posteriores (INCLUSIVE released) — senão run01 ressuscitaria
    # como ACTIVE quando run02 (que o supersedeu) fosse released.
    local -a active=()
    local c rd seq_now rd2 seq2
    for c in "${hist[@]:-}"; do
        [[ -z "${c}" ]] && continue
        seq_now="${c%%|*}"
        rd="${c#*|}"
        [[ -f "${rd}/.released" ]] && continue
        local ended=0
        local c2
        for c2 in "${hist[@]:-}"; do
            [[ -z "${c2}" ]] || [[ "${c2}" == "${c}" ]] && continue
            rd2="${c2#*|}"
            seq2="${c2%%|*}"
            (( 10#${seq2} > 10#${seq_now} )) || continue
            [[ -f "${rd2}/stale-supersedes" ]] || continue
            if grep -q "superseded_run: ${seq_now}" "${rd2}/stale-supersedes" 2>/dev/null; then
                ended=1
                break
            fi
        done
        [[ "${ended}" -eq 1 ]] && continue
        active+=("${rd}")
    done

    if [[ ${#active[@]} -eq 0 ]]; then
        return 1
    fi
    if [[ ${#active[@]} -gt 1 ]]; then
        return 2
    fi
    echo "${active[0]}"
    return 0
}

# Helpers de TASK e run_seq
# ---------------------------------------------------------------------------

_claim_task_file() {
    local worktree="${1:-}"
    local task_id="${2:-}"
    local matches=()
    local f
    # TASKs vivem no worktree do claimant: .kiro/tasks/<yyyymm>/<task_id>.md
    local nullglob_was_off=1
    shopt -q nullglob && nullglob_was_off=0
    shopt -s nullglob
    for f in "${worktree}"/.kiro/tasks/*/"${task_id}".md; do
        matches+=("${f}")
    done
    if (( nullglob_was_off )); then shopt -u nullglob; else shopt -s nullglob; fi

    if [[ ${#matches[@]} -eq 0 ]]; then
        echo "❌ TASK não encontrada no worktree: ${task_id} (procurei .kiro/tasks/*/${task_id}.md)" >&2
        return 1
    fi
    if [[ ${#matches[@]} -gt 1 ]]; then
        echo "❌ TASK_ID ambíguo: ${#matches[@]} arquivos para ${task_id}. Corrija com addendum." >&2
        return 1
    fi
    echo "${matches[0]}"
}

# run_seq GLOBAL por TASK (monotônico e nunca reutilizado entre worktrees):
# máximo entre (a) runs locais, (b) runs em TODOS os linked worktrees
# (`git worktree list` — Git continua SSOT do RUN) e (c) registro transitório
# de seqs atribuídos no diretório de locks compartilhado.
# Deve ser chamado DENTRO da seção crítica (mutex de claims): a escolha do seq
# ocorre no mutex compartilhado, então dois slots nunca escolhem o mesmo seq —
# mesmo quando um deles ainda não recebeu o merge do run do outro.
# O registro é append-only: release/stale/superseded NUNCA liberam um seq.
# Uso: _claim_next_run_seq <worktree> <task_id> <lock_dir>
_claim_next_run_seq() {
    local worktree="${1:-}"
    local task_id="${2:-}"
    local lock_dir="${3:-}"
    local max=0
    local run_dir seq wt

    # (a)+(b): runs duráveis em todos os worktrees vinculados ao repo.
    local wt_list=("${worktree}")
    while IFS= read -r wt; do
        [[ -n "${wt}" && -d "${wt}" ]] && wt_list+=("${wt}")
    done < <(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

    local runs_dir d
    for wt in "${wt_list[@]}"; do
        [[ -n "${wt}" && -d "${wt}" ]] || continue
        runs_dir="${wt}/.kiro/runs/${task_id}"
        [[ -d "${runs_dir}" ]] || continue
        local nullglob_was_off=1
        shopt -q nullglob && nullglob_was_off=0
        shopt -s nullglob
        local dirs=("${runs_dir}"/*/)
        if (( nullglob_was_off )); then shopt -u nullglob; else shopt -s nullglob; fi
        for d in "${dirs[@]}"; do
            [[ -d "${d}" ]] || continue
            seq="$(basename "${d}")"
            if [[ "${seq}" =~ ^[0-9]+$ ]] && (( 10#${seq} > max )); then
                max=$((10#${seq}))
            fi
        done
    done

    # (c): registro transitório de coordenação (seqs já atribuídos, em qualquer
    # worktree — cobre runs cujo merge ainda não chegou a este worktree).
    if [[ -n "${lock_dir}" && -f "${lock_dir}/.seq-registry" ]]; then
        while IFS= read -r seq; do
            if [[ "${seq}" =~ ^[0-9]+$ ]] && (( 10#${seq} > max )); then
                max=$((10#${seq}))
            fi
        done < "${lock_dir}/.seq-registry"
    fi
    printf '%02d' $((max + 1))
}

# ---------------------------------------------------------------------------
# claim --status / --check / --release / claim
# ---------------------------------------------------------------------------

_claim_cmd_status() {
    local task_id="${1:-}"
    if [[ -z "${task_id}" ]]; then
        echo "❌ Usage: agent-guard claim --status <task_id>" >&2
        return 1
    fi
    local main_repo lock_dir
    main_repo="$(_claim_main_repo)"
    lock_dir="$(_claim_task_lock_dir "${main_repo}" "${task_id}")"

    local scan_rc=0
    _claim_scan_active_locks "${lock_dir}" || scan_rc=$?
    if [[ ${scan_rc} -eq 2 ]]; then
        echo "${task_id}: CLAIM_CORRUPT (fail-closed — ESCALATION ao owner)"
        return 1
    fi
    if [[ ${#_CLAIM_ACTIVE_LOCKS[@]} -eq 0 ]]; then
        echo "${task_id}: UNCLAIMED"
        return 0
    fi
    local entry="${_CLAIM_ACTIVE_LOCKS[0]}"
    local seq="${entry%%:*}"
    local rest="${entry#*:}"
    local slot="${rest%%:*}"
    local wt="${rest#*:}"
    echo "${task_id}: CLAIMED by ${slot} (run ${seq}, worktree ${wt})"
}

_claim_cmd_check() {
    local task_id="${1:-}"
    if [[ -z "${task_id}" ]]; then
        echo "❌ Usage: agent-guard claim --check <task_id>" >&2
        return 1
    fi
    local worktree main_repo session_dir task_file
    worktree="$(_claim_worktree_root)"
    if [[ -z "${worktree}" ]]; then
        echo "❌ --check precisa rodar dentro de um repositório Git." >&2
        return 1
    fi
    main_repo="$(_claim_main_repo)"
    session_dir="$(_claim_session_dir "${main_repo}")"
    if ! task_file="$(_claim_task_file "${worktree}" "${task_id}")"; then
        return 1
    fi

    local risk_class
    risk_class="$(_task_get_field "${task_file}" "risk_class")"
    if [[ "${risk_class}" == "trivial" ]]; then
        echo "${task_id}: trivial — claim opcional. OK."
        return 0
    fi

    local lock_dir scan_rc=0
    lock_dir="$(_claim_task_lock_dir "${main_repo}" "${task_id}")"
    _claim_scan_active_locks "${lock_dir}" || scan_rc=$?
    if [[ ${scan_rc} -eq 2 ]]; then
        echo "${task_id}: CLAIM_CORRUPT (fail-closed)" >&2
        return 1
    fi
    if [[ ${#_CLAIM_ACTIVE_LOCKS[@]} -eq 0 ]]; then
        echo "${task_id}: sem claim ativo — rode 'agent-guard claim ${task_id}' (obrigatório para não-triviais)." >&2
        return 1
    fi

    local identity
    identity="$(_claim_current_identity)"
    local entry="${_CLAIM_ACTIVE_LOCKS[0]}"
    local active_seq="${entry%%:*}"
    local active_rest="${entry#*:}"
    local active_slot="${active_rest%%:*}"
    local active_wt="${active_rest#*:}"
    if [[ "${active_slot}" != "${identity}" ]]; then
        echo "${task_id}: claim de ${active_slot} — você não é o claimant." >&2
        return 1
    fi
    if [[ "${active_wt}" != "${worktree}" ]]; then
        echo "${task_id}: claim de ${active_slot} pertence a outro worktree (${active_wt}). Fail-closed." >&2
        return 1
    fi
    # Revalida a lease AGORA (autonomous_continue_rule): lock/identity/worktree
    # coincidindo não basta — lease released/stale/ausente => FAIL CLOSED.
    if ! _claim_verify_lease "${identity}" "${worktree}" "${session_dir}"; then
        echo "${task_id}: lease inválida — claim não verificável. Fail-closed." >&2
        return 1
    fi
    echo "${task_id}: claim OK (${identity}, run ${active_seq}, worktree ${worktree})."
}

# Seção crítica (dentro do mutex): scan + stale-take/supersede + CREATE do
# lock — tudo indivisível. Duas claims concorrentes: exatamente uma vence
# (a outra falha ao ver o lock, sem sobrescrever nada). Imprime "<run_seq>"
# em stdout e rc=0; mensagens de erro em stderr; rc=1 em falha.
# $5 (opcional): run_seq esperado via --run-seq — divergência é validada AQUI,
# antes do commit do lock, para que nenhum caminho de erro deixe lock fantasma.
_claim_acquire_critical() {
    local task_id="${1:-}"
    local identity="${2:-}"
    local worktree="${3:-}"
    local session_dir="${4:-}"
    local expected_seq="${5:-}"
    local branch="${6:-}"
    local confidence="${7:-media}"
    local plan_file="${8:-}"

    local lock_dir="$(_claim_task_lock_dir "$(_claim_main_repo)" "${task_id}")"
    mkdir -p "${lock_dir}"

    local scan_rc=0
    _claim_scan_active_locks "${lock_dir}" || scan_rc=$?
    if [[ ${scan_rc} -eq 2 ]]; then
        return 1
    fi

    local seq
    seq="$(_claim_next_run_seq "${worktree}" "${task_id}" "${lock_dir}")"
    # Validação do --run-seq explícito ANTES de qualquer mutação: divergência
    # retorna sem alterar NADA — nenhum lock fantasma, nenhum claim destruído.
    if [[ -n "${expected_seq}" && "${expected_seq}" != "${seq}" ]]; then
        echo "❌ --run-seq ${expected_seq} diverge do sequencial calculado (${seq}). Nada foi criado." >&2
        return 1
    fi

    # --- Fase 1: pré-validação (falha = invariante A: NADA muda) -----------
    local run_dir="${worktree}/.kiro/runs/${task_id}/${seq}"
    if [[ -e "${run_dir}" ]]; then
        # Único conteúdo legítimo pré-existente: stale-supersedes de takeover
        # anterior (mesmo fluxo/mutex). Outro conteúdo = fail-closed.
        local preexisting
        preexisting="$(ls -A "${run_dir}" 2>/dev/null || true)"
        if [[ -n "${preexisting}" && "${preexisting}" != "stale-supersedes" ]]; then
            echo "❌ run_dir já existe e não está vazio: ${run_dir}" >&2
            return 1
        fi
    fi
    local plan_text=""
    if [[ -n "${plan_file}" ]]; then
        if [[ ! -f "${plan_file}" ]]; then
            echo "❌ plan-file não encontrado: ${plan_file}" >&2
            return 1
        fi
        if ! plan_text="$(cat "${plan_file}" 2>/dev/null)"; then
            echo "❌ plan-file ilegível: ${plan_file}" >&2
            return 1
        fi
    fi
    if [[ -z "${branch}" ]]; then
        branch="$(git branch --show-current 2>/dev/null || echo "")"
    fi

    # --- Decisão do holder --------------------------------------------------
    # Holder é VÁLIDO iff session status == active E worktree_path == worktree
    # registrado no lock — independente de ser o mesmo slot. Divergência
    # (status inativo/ausente OU lease migrada) = STALE: o run antigo fica
    # duravelmente encerrado exclusivamente via stale-supersedes no run do
    # tomador; o worktree alheio NUNCA é escrito (isolamento).
    local renamed_lock="" rename_restore=""
    local stale_take=0
    local active_seq="" active_slot="" active_wt=""
    if [[ ${#_CLAIM_ACTIVE_LOCKS[@]} -eq 1 ]]; then
        local entry="${_CLAIM_ACTIVE_LOCKS[0]}"
        active_seq="${entry%%:*}"
        active_slot="${entry#*:}"; active_slot="${active_slot%%:*}"
        active_wt="${entry##*:}"
        local holder_session="${session_dir}/${active_slot}.json"
        local holder_status=""
        local holder_wt=""
        if [[ -f "${holder_session}" ]]; then
            holder_status="$("${AG_PYTHON}" -c "import json;print(json.load(open('${holder_session}')).get('status',''))" 2>/dev/null || true)"
            holder_wt="$("${AG_PYTHON}" -c "import json;print(json.load(open('${holder_session}')).get('worktree_path',''))" 2>/dev/null || true)"
        fi
        if [[ "${holder_status}" == "active" && "${holder_wt}" == "${active_wt}" ]]; then
            if [[ "${active_slot}" != "${identity}" ]]; then
                echo "❌ TASK ${task_id} já tem claim ativo: slot ${active_slot} (run ${active_seq}). Um TASK, um claimant por vez." >&2
                echo "   Aguarde release ou escale ao owner." >&2
                return 1
            fi
            # Mesmo slot + mesmo worktree + lease viva = reclaim (rework).
            renamed_lock="${lock_dir}/${active_seq}.lock.superseded.$(date +%s)"
        else
            # STALE (inclusive mesmo slot com worktree migrado).
            stale_take=1
            renamed_lock="${lock_dir}/${active_seq}.lock.stale.$(date +%s)"
            rename_restore="${lock_dir}/${active_seq}.lock"
        fi
    fi

    # --- Fase 2: materializar o NOVO run (apenas no nosso worktree) ---------
    # Falha aqui = rollback só do nosso run dir: o estado compartilhado ainda
    # está intacto (invariante A preservada — nada de intermediário publicado).
    local now
    now="$(date -Iseconds)"
    if ! mkdir -p "${run_dir}/evidence" 2>/dev/null; then
        echo "❌ Falha de I/O criando ${run_dir}; nada foi publicado." >&2
        return 1
    fi
    if [[ ${stale_take} -eq 1 ]]; then
        # Representação DURÁVEL do stale-take (regra canônica no header do
        # arquivo): run antigo duravelmente encerrado sem lock transitório.
        if ! {
            echo "superseded_run: ${active_seq}"
            echo "superseded_slot: ${active_slot}"
            echo "superseded_worktree: ${active_wt}"
            echo "taken_by: ${identity}"
            echo "taken_at: ${now}"
            echo "reason: stale_lease"
        } > "${run_dir}/stale-supersedes" 2>/dev/null; then
            rm -rf "${run_dir}"
            echo "❌ Falha de I/O gravando stale-supersedes; nada foi publicado." >&2
            return 1
        fi
        if command -v _journal_write_event >/dev/null 2>&1; then
            _journal_write_event "task.claim_stale_taken" "{\"task_id\":\"${task_id}\",\"stale_slot\":\"${active_slot}\",\"stale_worktree\":\"${active_wt}\",\"new_slot\":\"${identity}\"}" "$(pwd)" || true
        fi
    fi
    if ! {
        echo "---"
        echo "task_id: ${task_id}"
        echo "run_seq: ${seq}"
        echo "slot: ${identity}"
        echo "branch: ${branch:-<não definida>}"
        echo "claimed_at: ${now}"
        echo "confidence: ${confidence}"
        echo "---"
        echo ""
        echo "# CLAIM — ${task_id} run ${seq}"
        echo ""
        echo "## Plano (≤10 linhas)"
        echo ""
        if [[ -n "${plan_text}" ]]; then
            echo "${plan_text}"
        else
            echo "1. <preencher>"
        fi
    } > "${run_dir}/claim.md" 2>/dev/null; then
        rm -rf "${run_dir}"
        echo "❌ Falha de I/O gravando claim.md; nada foi publicado." >&2
        return 1
    fi
    {
        echo "# execution-log — ${task_id} run ${seq}"
        echo ""
        echo "- ${now} | claim | run_seq ${seq} aberto por ${identity} na branch ${branch:-<nenhuma>}"
    } > "${run_dir}/execution-log.md" 2>/dev/null || true
    local tmpl_evidence="${worktree}/.kiro/runs/TEMPLATE-run/evidence/README.md"
    if [[ -f "${tmpl_evidence}" && ! -f "${run_dir}/evidence/README.md" ]]; then
        cp "${tmpl_evidence}" "${run_dir}/evidence/README.md" 2>/dev/null || true
    fi

    # --- Fase 3: commit do estado compartilhado (rollback em falha) ---------
    if [[ ${stale_take} -eq 0 && -n "${renamed_lock}" ]]; then
        # Reclaim: trilha durável no run anterior (NOSSO worktree — legítimo).
        local prev_run_dir="${active_wt}/.kiro/runs/${task_id}/${active_seq}"
        if [[ -d "${prev_run_dir}" && ! -f "${prev_run_dir}/.released" ]]; then
            {
                echo "released_by: ${identity}"
                echo "released_at: $(date -Iseconds)"
                echo "reason: superseded_by_reclaim"
            } > "${prev_run_dir}/.released" 2>/dev/null || true
        fi
    fi
    if [[ -n "${renamed_lock}" ]]; then
        rename_restore="${rename_restore:-${lock_dir}/${active_seq}.lock}"
        if ! mv "${lock_dir}/${active_seq}.lock" "${renamed_lock}" 2>/dev/null; then
            rm -rf "${run_dir}"
            echo "❌ Falha de I/O na transição do lock; transação revertida." >&2
            return 1
        fi
    fi
    if ! {
        echo "slot=${identity}"
        echo "worktree=${worktree}"
        echo "run_seq=${seq}"
        echo "claimed_at=${now}"
    } > "${lock_dir}/${seq}.lock" 2>/dev/null; then
        if [[ -n "${renamed_lock}" && -f "${renamed_lock}" ]]; then
            mv "${renamed_lock}" "${rename_restore}" 2>/dev/null || true
        fi
        rm -rf "${run_dir}"
        echo "❌ Falha de I/O criando o lock; transação revertida." >&2
        return 1
    fi
    # Registro transitório (dentro do mutex): seq atribuído nunca é reutilizado,
    # mesmo se o run for liberado/removido antes do merge em outros worktrees.
    echo "${seq}" >> "${lock_dir}/.seq-registry" 2>/dev/null || true

    if [[ ${stale_take} -eq 1 ]]; then
        echo "⚠️  Lock stale de '${active_slot}' (sem lease ativa no worktree ${active_wt}) tomado por ${identity}." >&2
    fi
    # Últimas linhas de stdout: <branch> e <run_seq> (o caller captura ambos).
    echo "${branch}"
    echo "${seq}"
}

_claim_cmd_claim() {
    local task_id=""
    local run_seq=""
    local branch=""
    local confidence="media"
    local plan_file=""

    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --run-seq) run_seq="${2:-}"; shift 2 ;;
            --branch) branch="${2:-}"; shift 2 ;;
            --confidence) confidence="${2:-}"; shift 2 ;;
            --plan-file) plan_file="${2:-}"; shift 2 ;;
            --*) echo "❌ Opção desconhecida: ${1}" >&2; return 1 ;;
            *)
                if [[ -z "${task_id}" ]]; then task_id="${1}"; shift; else shift; fi ;;
        esac
    done

    if [[ -z "${task_id}" ]]; then
        echo "❌ Usage: agent-guard claim <task_id> [--run-seq NN] [--branch B] [--confidence C] [--plan-file P]" >&2
        return 1
    fi

    case "${confidence}" in
        alta|media|baixa) ;;
        *) echo "❌ confidence inválida: ${confidence} (alta|media|baixa)" >&2; return 1 ;;
    esac

    # Fail-closed: precisa ser um repositório Git (estado durável).
    local worktree
    worktree="$(_claim_worktree_root)"
    if [[ -z "${worktree}" ]]; then
        echo "❌ claim requer um repositório Git (estado durável em .kiro/runs/)." >&2
        return 1
    fi

    local main_repo session_dir
    main_repo="$(_claim_main_repo)"
    session_dir="$(_claim_session_dir "${main_repo}")"

    local task_file
    if ! task_file="$(_claim_task_file "${worktree}" "${task_id}")"; then
        return 1
    fi

    # Lease real: identidade válida + session ativa + worktree dono.
    local identity
    identity="$(_claim_current_identity)"
    if [[ -z "${identity}" ]]; then
        echo "❌ Não foi possível resolver a identidade do slot." >&2
        return 1
    fi
    if ! _claim_verify_lease "${identity}" "${worktree}" "${session_dir}"; then
        return 1
    fi

    # base_ref do TASK deve ser resolvível (fail-closed).
    local base_ref
    base_ref="$(_task_get_field "${task_file}" "base_ref")"
    if [[ -n "${base_ref}" ]]; then
        if ! git cat-file -e "${base_ref}^{commit}" 2>/dev/null; then
            echo "❌ base_ref '${base_ref}' do TASK não resolve neste repositório." >&2
            echo "   Rebase/reconcile o TASK (addendum) antes de claim." >&2
            return 1
        fi
    fi

    if [[ -n "${run_seq}" && ! "${run_seq}" =~ ^[0-9]{2}$ ]]; then
        echo "❌ run_seq inválido: ${run_seq} (formato NN)" >&2
        return 1
    fi

    # Aquisição + transição + materialização DURÁVEL: tudo dentro da seção
    # crítica (mutex flock). Invariante transacional: falha = nada publicado
    # (claim anterior continua o único válido); sucesso = run completo, único
    # claim duravelmente ativo. Nunca existe estado intermediário.
    local acquire_rc=0
    local acquire_tmp
    acquire_tmp="$(mktemp)"
    _claim_with_mutex "${main_repo}" _claim_acquire_critical "${task_id}" "${identity}" "${worktree}" "${session_dir}" "${run_seq}" "${branch}" "${confidence}" "${plan_file}" \
        > "${acquire_tmp}" && acquire_rc=0 || acquire_rc=$?
    if [[ ${acquire_rc} -ne 0 ]]; then
        rm -f "${acquire_tmp}"
        return 1
    fi
    local -a acquire_lines=()
    mapfile -t acquire_lines < "${acquire_tmp}"
    rm -f "${acquire_tmp}"
    local acquired_seq="${acquire_lines[-1]:-}"
    branch="${acquire_lines[-2]:-}"
    if [[ ! "${acquired_seq}" =~ ^[0-9]{2}$ ]]; then
        echo "❌ Falha ao resolver run_seq da aquisição ('${acquired_seq}'). Fail-closed." >&2
        return 1
    fi
    if [[ -n "${run_seq}" && "${run_seq}" != "${acquired_seq}" ]]; then
        # Defesa em profundidade: a divergência já foi validada dentro da
        # seção crítica. Chegar aqui é inconsistência interna — fail-closed.
        echo "❌ --run-seq ${run_seq} diverge do adquirido (${acquired_seq}). Fail-closed." >&2
        return 1
    fi
    run_seq="${acquired_seq}"

    local run_dir="${worktree}/.kiro/runs/${task_id}/${run_seq}"
    local now
    now="$(date -Iseconds)"

    # Nota do slot referencia task_id/run_seq (referência, não cópia).
    local note_path
    note_path="$(_task_note_path "${identity}" "${worktree}")"
    if [[ ! -f "${note_path}" ]]; then
        echo "⚠️  Nota de slot ausente; criando nota mínima para ${identity}."
        mkdir -p "$(dirname "${note_path}")"
        chmod 700 "$(dirname "${note_path}")" 2>/dev/null || true
    fi
    local json updated
    json="$(_task_read_frontmatter "${note_path}")"
    updated="$(_task_update_metadata "${json}" "task_id" "${task_id}")"
    updated="$(_task_update_metadata "${updated}" "run_seq" "${run_seq}")"
    updated="$(_task_update_metadata "${updated}" "updated_at" "${now}")"
    _task_write_note "${note_path}" "${updated}" "$(_task_get_field "${note_path}" "body")"

    if command -v _journal_write_event >/dev/null 2>&1; then
        _journal_write_event "task.claimed" "{\"task_id\":\"${task_id}\",\"run_seq\":\"${run_seq}\",\"slot\":\"${identity}\",\"worktree\":\"${worktree}\",\"branch\":\"${branch}\"}" "${worktree}" || true
    fi

    echo "✅ CLAIM: ${task_id} run ${run_seq} — slot ${identity} (worktree ${worktree})"
    echo "   claim.md: ${run_dir}/claim.md"
    echo "   Commit o run dir para tornar o CLAIM durável em Git."
}

_claim_cmd_release() {
    local task_id=""
    local run_seq=""
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --run-seq) run_seq="${2:-}"; shift 2 ;;
            --*) echo "❌ Opção desconhecida: ${1}" >&2; return 1 ;;
            *)
                if [[ -z "${task_id}" ]]; then task_id="${1}"; shift; else shift; fi ;;
        esac
    done
    if [[ -z "${task_id}" ]]; then
        echo "❌ Usage: agent-guard claim --release <task_id> [--run-seq NN]" >&2
        return 1
    fi

    local worktree main_repo session_dir identity
    worktree="$(_claim_worktree_root)"
    if [[ -z "${worktree}" ]]; then
        echo "❌ --release precisa rodar dentro de um repositório Git." >&2
        return 1
    fi
    main_repo="$(_claim_main_repo)"
    session_dir="$(_claim_session_dir "${main_repo}")"
    identity="$(_claim_current_identity)"

    local lock_dir
    lock_dir="$(_claim_task_lock_dir "${main_repo}" "${task_id}")"

    # Seção crítica: verificar + liberar indivisíveis.
    local release_rc=0
    _claim_with_mutex "${main_repo}" _claim_release_critical \
        "${task_id}" "${identity}" "${worktree}" "${lock_dir}" "${run_seq}" || release_rc=$?
    return "${release_rc}"
}

# Seção crítica do release (dentro do mutex).
_claim_release_critical() {
    local task_id="${1:-}"
    local identity="${2:-}"
    local worktree="${3:-}"
    local lock_dir="${4:-}"
    local run_seq="${5:-}"

    local scan_rc=0
    _claim_scan_active_locks "${lock_dir}" || scan_rc=$?
    if [[ ${scan_rc} -eq 2 ]]; then
        return 1
    fi
    if [[ ${#_CLAIM_ACTIVE_LOCKS[@]} -eq 0 ]]; then
        echo "❌ TASK ${task_id} não tem claim ativo." >&2
        return 1
    fi

    local entry="${_CLAIM_ACTIVE_LOCKS[0]}"
    local active_seq="${entry%%:*}"
    local active_slot="${entry#*:}"; active_slot="${active_slot%%:*}"
    local active_wt="${entry##*:}"

    if [[ "${active_slot}" != "${identity}" || "${active_wt}" != "${worktree}" ]]; then
        echo "❌ Claim ativo pertence a ${active_slot} (${active_wt}); só o claimant no próprio worktree pode release." >&2
        return 1
    fi
    if [[ -n "${run_seq}" && "${run_seq}" != "${active_seq}" ]]; then
        echo "❌ run_seq ativo é ${active_seq}, não ${run_seq}. Nada foi liberado." >&2
        return 1
    fi

    # Remove o lock compartilhado (histórico fica no run dir + journal).
    rm -f "${lock_dir}/${active_seq}.lock"

    # .released no run dir do worktree (trilha durável).
    local run_dir="${worktree}/.kiro/runs/${task_id}/${active_seq}"
    if [[ -d "${run_dir}" ]]; then
        {
            echo "released_by: ${identity}"
            echo "released_at: $(date -Iseconds)"
            echo "reason: released"
        } > "${run_dir}/.released"
    fi

    # Limpa a referência na nota SOMENTE se ainda aponta exatamente para
    # este claim (não apaga referência de claim mais nova por race).
    local note_path json cur_task cur_seq updated
    note_path="$(_task_note_path "${identity}" "${worktree}")"
    if [[ -f "${note_path}" ]]; then
        json="$(_task_read_frontmatter "${note_path}")"
        cur_task="$(_task_get_field "${note_path}" "task_id")"
        cur_seq="$(_task_get_field "${note_path}" "run_seq")"
        if [[ "${cur_task}" == "${task_id}" && ( -z "${cur_seq}" || "${cur_seq}" == "${active_seq}" ) ]]; then
            updated="$(_task_update_metadata "${json}" "task_id" "")"
            updated="$(_task_update_metadata "${updated}" "run_seq" "")"
            updated="$(_task_update_metadata "${updated}" "updated_at" "$(date -Iseconds)")"
            _task_write_note "${note_path}" "${updated}" "$(_task_get_field "${note_path}" "body")"
        fi
    fi

    if command -v _journal_write_event >/dev/null 2>&1; then
        _journal_write_event "task.claim_released" "{\"task_id\":\"${task_id}\",\"run_seq\":\"${active_seq}\",\"slot\":\"${identity}\",\"worktree\":\"${worktree}\"}" "${worktree}" || true
    fi
    echo "✅ RELEASE: ${task_id} run ${active_seq} liberado por ${identity}."
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

_claim_cli_main() {
    local subcommand="${1:-}"
    shift 2>/dev/null || true
    case "${subcommand}" in
        ""|help|--help|-h)
            cat <<'EOF'
Uso: agent-guard claim <task_id> [opções]
     agent-guard claim --status <task_id>
     agent-guard claim --check <task_id>
     agent-guard claim --release <task_id> [--run-seq NN]

Opções de claim:
  --run-seq NN                 Sequência do run (default: próxima livre)
  --branch B                   Branch do run (default: branch atual)
  --confidence alta|media|baixa
  --plan-file P                Arquivo com o plano (≤10 linhas)

Regras (F0-F S2):
  - claim.md é obrigatório para TASKs com risk_class != trivial;
  - estado durável (claim.md/run dir) vive no WORKTREE do claimant, em Git;
  - exclusividade usa lock compartilhado em <main_repo>/.kiro/locks/claims/
    (coordenação transitória — não é uma segunda store durável);
  - aquisição atômica (mutex flock + scan + create); um TASK, um claimant;
  - exige lease ativa do slot no worktree corrente (fail-closed);
  - release limpa a referência task_id/run_seq da nota do slot;
  - fail-closed: TASK ausente/ambígua, base_ref que não resolve, claim
    corrompido (>1 ativo ou slot vazio) => ESCALATION ao owner.
EOF
            return 0
            ;;
        --status)
            _claim_cmd_status "$@"
            return $?
            ;;
        --check)
            _claim_cmd_check "$@"
            return $?
            ;;
        --release)
            _claim_cmd_release "$@"
            return $?
            ;;
        -*)
            echo "❌ Subcomando desconhecido: ${subcommand}" >&2
            echo "   Use: agent-guard claim help" >&2
            return 1
            ;;
        *)
            _claim_cmd_claim "${subcommand}" "$@"
            return $?
            ;;
    esac
}
