#!/usr/bin/env bash
#
# PUSH TRANSITION PRIMITIVE — Agent Guard Core (SSOT)
#
# Única primitiva de resolução de transição de push. Consome o protocolo Git
# de stdin do hook pre-push:
#
#     <local-ref> <local-sha> <remote-ref> <remote-sha>   (uma linha por ref)
#
# e classifica cada tupla isoladamente:
#
#   - FAST_FORWARD : remote_sha é ancestral de local_sha
#   - FIRST_PUSH   : remote_sha zero (branch nova no remoto)
#   - REWRITE      : non-fast-forward (remote_sha NÃO é ancestral)
#   - DELETE       : local_sha zero (deleção de ref)
#   - TAG          : refs/tags/*
#   - NOTES_REF    : refs/notes/*, refs/agent-guard/* (fluxo dedicado)
#
# Consumidores desta primitiva (SSOT da operação de push):
#   1. roteamento ref↔worktree — ref ia-<identidade>/* só pode ser empurrada
#      pelo worktree configurado com o e-mail correspondente (nunca de
#      `git branch --show-current` nem de origin/$BRANCH fetchado pré-push);
#      auditoria de AUTORIA do range (commits com e-mail do slot) é autoridade
#      do G8.3 no CI + pre-commit local — removida daqui na F1 (#7604/#7608);
#   2. worktree-origin audit (notes) — validação no range candidato;
#   3. autorização de rewrite — rebase puro COMPROVADO (patch + autoria +
#      proveniência preservados, sem ambiguidade, sem merge remoto removido)
#      é o único auto-autorizado; remoção real de commits é BLOCK
#      INCONDICIONAL. Grants locais foram REMOVIDOS como autorização: não
#      comprovam autoridade humana (a IA pode auto-concedê-los). Mecanismo
#      de autoridade verificável é contrato de fase posterior (ADR-0060).
#
# Invariantes:
#   - stdin vazio/malformado  -> BLOCK (fail-closed);
#   - múltiplas refs          -> cada tupla validada isoladamente; qualquer
#     tupla inválida bloqueia a operação inteira;
#   - deleção de branch/tag por agente -> BLOCK (policy explícita);
#   - identidade e branch derivadas das refs submetidas;
#   - first push NUNCA pula os audits de proveniência/rewrite: trusted base =
#     merge-base exato (único) com a base configurada; ausente/ambíguo -> BLOCK;
#   - rewrite: rebase puro comprovado (patch+autoria+proveniência preservados,
#     sem ambiguidade, sem merge remoto removido) é o único caso auto-autorizado;
#     qualquer remoção real de commits é BLOCK INCONDICIONAL — não existe grant
#     local aceito (não comprova autoridade humana; ver ADR-0060/ADR-0061);
#   - sem mecanismo de bypass por env var nesta primitiva. O único bypass
#     existente (HMVIP_AGENT_GUARD_BYPASS) permanece exclusivo do
#     lease-owner-check (posse de lease) e NÃO afeta auditoria de transição.
#
# Uso (sourced, dentro do hook pre-push, com stdin do Git disponível):
#   source ".../hooks/push-transition.sh"
#   push_transition_audit "${remote_name:-origin}" || exit 1
#
# Após sucesso, variáveis de resultado (single agent-branch tuple):
#   PT_CLASS, PT_BRANCH, PT_IDENTITY, PT_EXPECTED_EMAIL, PT_CANDIDATE_RANGE,
#   PT_LOCAL_SHA, PT_REMOTE_SHA
# E para consumidores multi-tupla:
#   PT_STDIN_LINES (array com as linhas brutas do stdin — realimentar o PAS),
#   PT_AGENT_BRANCHES (array "branch:identity" das tuplas de branch de agente).

# NÃO usar set -e/-u aqui: este arquivo é sourceado por hooks e scripts do
# usuário (hmvip-shell-safety / incidente L222). Todas as checagens usam
# formas condicionais explícitas.

# -----------------------------------------------------------------------------
# Parsing do stdin
# -----------------------------------------------------------------------------

PT_STDIN_LINES=()
PT_AGENT_BRANCHES=()
PT_CLASS=""
PT_BRANCH=""
PT_IDENTITY=""
PT_EXPECTED_EMAIL=""
PT_CANDIDATE_RANGE=""
PT_LOCAL_SHA=""
PT_REMOTE_SHA=""

_pt_err() {
    echo "❌❌❌ PUSH BLOCKED: TRANSITION AUDIT ❌❌❌" >&2
    echo "" >&2
    echo "$1" >&2
    echo "" >&2
}

# Lê e valida o stdin do protocolo pre-push. Retorna 1 (com mensagem) se
# vazio, TTY, ou com qualquer linha malformada.
_pt_read_stdin() {
    if [[ -t 0 ]]; then
        _pt_err "Sem stdin do protocolo pre-push (terminal interativo detectado).
O hook só pode ser executado pelo próprio 'git push' (stdin com as tuplas
<local-ref> <local-sha> <remote-ref> <remote-sha>)."
        return 1
    fi

    local line
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        PT_STDIN_LINES+=("${line}")
    done

    if [[ "${#PT_STDIN_LINES[@]}" -eq 0 ]]; then
        _pt_err "stdin do pre-push VAZIO. Sem tuplas de transição não há nada a
autorizar. Causas conhecidas: (1) invocação fora do protocolo Git (hook
manual, harness que não repassou stdin); (2) o próprio Git rejeitou TODAS as
refs localmente antes do hook — típico de non-fast-forward sem --force, caso
em que o push falharia de qualquer forma com '! [rejected] (non-fast-forward)'
na saída do git. Nenhuma exceção: fail-closed."
        return 1
    fi

    local lr ls rr rs resolved
    local -i i=0
    for line in "${PT_STDIN_LINES[@]}"; do
        i=$((i + 1))
        read -r lr ls rr rs <<< "${line}"
        if [[ -z "${lr:-}" || -z "${ls:-}" || -z "${rr:-}" || -z "${rs:-}" \
            || "${rr}" != refs/* \
            || ! "${ls}" =~ ^[0-9a-f]{7,64}$ \
            || ! "${rs}" =~ ^[0-9a-f]{7,64}$ ]]; then
            _pt_err "Tupla ${i} malformada (linha: '${line}').
Esperado: <local-ref> <local-sha> <remote-ref> <remote-sha> com SHAs hex."
            return 1
        fi
        # <local-ref> pode vir como nome simbólico (ex.: 'HEAD' quando o
        # refspec é 'git push origin HEAD'): nesse caso o Git reporta
        # literalmente 'HEAD' no campo. Validação: deve resolver ao
        # <local-sha> declarado. <remote-ref> é quem dá branch/identidade
        # (é a ref que o servidor atualizará) e sempre vem em refs/*.
        if [[ "${lr}" != refs/* ]]; then
            resolved="$(git rev-parse --verify --quiet "${lr}^{commit}" 2>/dev/null || echo "")"
            if [[ "${resolved}" != "${ls}" || -z "${resolved}" ]]; then
                _pt_err "Tupla ${i} com <local-ref> '${lr}' que não resolve ao
<local-sha> '${ls}'. Recusando ref ambígua/forjada (linha: '${line}')."
                return 1
            fi
        fi
    done
    return 0
}

# -----------------------------------------------------------------------------
# Config / identidade (mesma derivação do pre-push — yaml é a SSOT de config)
# -----------------------------------------------------------------------------

PT_CONFIG_BIN=""
PT_DOMAIN=""
PT_PROTECTED_BRANCHES=""
PT_NOTES_REF=""
PT_BASE_BRANCH=""

_pt_load_config() {
    local hook_dir repo_root git_common_dir
    hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    [[ -n "${repo_root}" ]] || return 1
    git_common_dir="$(git -C "${repo_root}" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "${git_common_dir}" = /* ]]; then
        PT_GIT_COMMON_DIR="${git_common_dir}"
        PT_REPO_ROOT="$(cd "$(dirname "${git_common_dir}")" 2>/dev/null && pwd || echo "${repo_root}")"
    else
        PT_GIT_COMMON_DIR="$(cd "${repo_root}/${git_common_dir}" 2>/dev/null && pwd || echo "${repo_root}/.git")"
        PT_REPO_ROOT="$(cd "${PT_GIT_COMMON_DIR}/.." 2>/dev/null && pwd || echo "${repo_root}")"
    fi
    PT_HOOK_DIR="${hook_dir}"
    PT_CONFIG_BIN="${PT_REPO_ROOT}/packages/agent-guard-core/bin/agent-guard-config"
    [[ -f "${PT_CONFIG_BIN}" ]] || return 1

    local name template
    for name in $(bash "${PT_CONFIG_BIN}" keys identities 2>/dev/null); do
        template="$(bash "${PT_CONFIG_BIN}" get "identities.${name}.author_email" '' 2>/dev/null)"
        if [[ "${template}" =~ @([^[:space:]]+)$ ]]; then
            PT_DOMAIN="${BASH_REMATCH[1]}"
            break
        fi
    done
    PT_PROTECTED_BRANCHES="$(bash "${PT_CONFIG_BIN}" get git.protected_branches 'main master develop' 2>/dev/null)"
    PT_NOTES_REF="$(bash "${PT_CONFIG_BIN}" get git.notes_ref 'refs/notes/agent-guard-worktree' 2>/dev/null)"
    PT_BASE_BRANCH="$(bash "${PT_CONFIG_BIN}" get git.base_branch 'develop' 2>/dev/null)"
    [[ -n "${PT_DOMAIN}" && -n "${PT_NOTES_REF}" && -n "${PT_BASE_BRANCH}" ]]
}

# Resolve e-mail de agente -> identidade (ex.: agent-kimi6@example.com -> kimi6).
_pt_identity_from_email() {
    local email="$1" name template base
    [[ -n "${PT_DOMAIN}" ]] || return 0
    for name in $(bash "${PT_CONFIG_BIN}" keys identities 2>/dev/null); do
        template="$(bash "${PT_CONFIG_BIN}" get "identities.${name}.author_email" '' 2>/dev/null)"
        [[ "${template}" =~ ^agent-(.+)\{n\}@${PT_DOMAIN}$ ]] || continue
        base="${BASH_REMATCH[1]}"
        if [[ "${email}" =~ ^agent-${base}([0-9]+)@${PT_DOMAIN}$ ]]; then
            echo "${name}${BASH_REMATCH[1]}"
            return 0
        fi
    done
    return 0
}

# O e-mail esperado para uma identidade derivada da ref (ex.: kimi6 -> agent-kimi6@...).
_pt_expected_email_for() {
    local identity="$1" name template n base
    n="${identity##*[a-z]}"   # sufixo numérico: kimi6 -> 6
    base="${identity%"${n}"}" # base alfabética: kimi6 -> kimi
    for name in $(bash "${PT_CONFIG_BIN}" keys identities 2>/dev/null); do
        [[ "${name}" == "${base}" ]] || continue
        template="$(bash "${PT_CONFIG_BIN}" get "identities.${name}.author_email" '' 2>/dev/null)"
        if [[ "${template}" =~ \{n\}@(.*)$ ]]; then
            echo "agent-${base}${n}@${BASH_REMATCH[1]}"
            return 0
        fi
    done
    echo "agent-${identity}@${PT_DOMAIN}"
}

_pt_is_protected() {
    local b
    for b in ${PT_PROTECTED_BRANCHES}; do
        [[ "$1" == "${b}" ]] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# Autorização de rewrite — SEM grants locais
#
# Decisão arquitetural (revisão da PR #7444, ADR-0060): grants armazenados em
# <git-common-dir> NÃO comprovam autoridade humana — a mesma IA que executa
# Git/shell pode executar o CLI de grant ou escrever o arquivo diretamente.
# Autoautorização local não é boundary. Por isso:
#   - remoção real de commits em rewrite é BLOCK INCONDICIONAL;
#   - o único rewrite autoautorizado é o "rebase puro comprovado" (abaixo);
#   - mecanismo de autoridade humana VERIFICÁVEL (chave privada fora do
#     alcance do processo da IA / serviço externo de aprovação / separação real
#     de usuário no SO / artefato autenticado) fica como contrato de fase
#     posterior (ADR-0060/ADR-0061). Não foi inventado nenhum mecanismo
#     criptográfico nesta PR e nenhum CLI local é consumido como autorização.
# -----------------------------------------------------------------------------

# Rebase puro comprovado: cada commit remoto substituído precisa de match
# INEQUÍVOCO no candidato com, cumulativamente:
#   1. patch equivalente (patch-id estável);
#   2. mesma identidade/autoria canônica (%ae e %an idênticos);
#   3. proveniência preservada: commit de IA deve carregar worktree note com
#      identity e branch correspondentes (contrato de notes);
#   4. nenhuma ambiguidade de mapeamento (1 remoto ↔ exatamente 1 candidato);
#   5. nenhum merge commit remoto removido ou ocultado (merges NÃO entram no
#      dedup — um merge remoto que desaparece é remoção real, sem exceção).
# Qualquer condição não comprovada = remoção real = BLOCK.
# Uso: _pt_rewrite_check_purity <local_sha> <remote_sha> <expected_email> \
#          <identity> <branch>   → silence/exit 0 se puro; motivos/exit 1 se não.
_pt_rewrite_check_purity() {
    local local_sha="$1" remote_sha="$2" expected_email="$3" identity="$4" branch="$5"

    # (5) Merge commits remotos removidos: qualquer merge alcançável do
    # remoto e não alcançável do candidato sumiu do histórico.
    local m
    while IFS= read -r m; do
        [[ -n "${m}" ]] || continue
        echo "MERGE_REMOVED ${m}"
        return 1
    done < <(git rev-list --merges "${remote_sha}" --not "${local_sha}" 2>/dev/null)

    # Índice de patch-ids do lado candidato (commits novos, sem merges —
    # merges novos são adições legítimas e não precisam de match). Patch-ids
    # repetidos são acumulados para detecção de ambiguidade no match.
    local -A cand=()
    local c pid
    while IFS= read -r c; do
        [[ -n "${c}" ]] || continue
        pid="$(git show --pretty=format: --patch "${c}" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')"
        [[ -z "${pid}" ]] && continue
        if [[ -n "${cand[${pid}]:-}" ]]; then
            cand["${pid}"]+=" ${c}"
        else
            cand["${pid}"]="${c}"
        fi
    done < <(git rev-list --no-merges "${local_sha}" --not "${remote_sha}" 2>/dev/null)

    # Cada commit remoto substituído precisa de correspondência inequívoca.
    local r matches n match rae cae ran can note
    while IFS= read -r r; do
        [[ -n "${r}" ]] || continue
        pid="$(git show --pretty=format: --patch "${r}" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')"
        if [[ -z "${pid}" ]]; then
            # Commit remoto sem patch comprovável (vazio/irregular): não
            # comprovável = remoção real.
            echo "REMOVED ${r}"
            return 1
        fi
        matches="${cand[${pid}]:-}"
        if [[ -z "${matches}" ]]; then
            echo "REMOVED ${r}"
            return 1
        fi
        n="$(wc -w <<< "${matches}")"
        if [[ "${n}" -ne 1 ]]; then
            echo "AMBIGUOUS ${r} matches=${n}"
            return 1
        fi
        match="${matches// /}"

        # (2) autoria canônica preservada
        rae="$(git log -1 --pretty=%ae "${r}" 2>/dev/null || echo "")"
        cae="$(git log -1 --pretty=%ae "${match}" 2>/dev/null || echo "")"
        ran="$(git log -1 --pretty=%an "${r}" 2>/dev/null || echo "")"
        can="$(git log -1 --pretty=%an "${match}" 2>/dev/null || echo "")"
        if [[ -z "${rae}" || -z "${cae}" || "${rae}" != "${cae}" || "${ran}" != "${can}" ]]; then
            echo "AUTHOR_CHANGED ${r} autor_remoto='${rae}' autor_candidato='${cae}'"
            return 1
        fi

        # (3) proveniência: autor de IA exige worktree note com identity/branch
        if [[ "${cae}" == "${expected_email}" ]]; then
            note="$(git notes --ref="${PT_NOTES_REF}" show "${match}" 2>/dev/null || echo "")"
            if ! grep -q "^identity:${identity}$" <<< "${note}" \
                || ! grep -q "^branch:${branch}$" <<< "${note}"; then
                echo "PROVENANCE_LOST ${match}"
                return 1
            fi
        fi
    done < <(git rev-list --no-merges "${remote_sha}" --not "${local_sha}" 2>/dev/null)

    return 0
}

_pt_journal() {
    # Best-effort: journal só existe no contexto HMVIP. Serialização JSON
    # real (python3 json.dumps): aspas, Unicode, barras e caracteres de
    # controle nos valores nunca corrompem nem injetam registros no JSONL.
    local event="$1" detail="$2"
    local journal="${PT_REPO_ROOT}/.agent-guard/journal/agent-guard.jsonl"
    [[ -f "${journal}" ]] || return 0
    python3 - "${journal}" "${event}" "${detail}" <<'PY' 2>/dev/null || true
import json, sys, time
path, event, detail = sys.argv[1], sys.argv[2], sys.argv[3]
line = json.dumps(
    {"ts": int(time.time()), "event": event, "detail": detail},
    ensure_ascii=False,
)
with open(path, "a", encoding="utf-8") as fh:
    fh.write(line + "\n")
PY
}

# -----------------------------------------------------------------------------
# Trusted base (first push / rewrite) — fail-closed
# -----------------------------------------------------------------------------

# Garante refs/remotes/<remote>/<base_branch> disponível e imprime o merge-base
# ÚNICO entre a base e o local_sha. Falha (return 1) se ausente/ambíguo.
_pt_trusted_base() {
    local remote_name="$1" local_sha="$2"
    if ! git rev-parse --verify --quiet "refs/remotes/${remote_name}/${PT_BASE_BRANCH}" >/dev/null 2>&1; then
        git fetch --no-tags "${remote_name}" "${PT_BASE_BRANCH}" >/dev/null 2>&1 || true
    fi
    if ! git rev-parse --verify --quiet "refs/remotes/${remote_name}/${PT_BASE_BRANCH}" >/dev/null 2>&1; then
        _pt_err "Trusted base indisponível: '${remote_name}/${PT_BASE_BRANCH}' não existe e
não pôde ser fetchado. First push e rewrite exigem base configurada
verificável. Falhando fechado."
        return 1
    fi
    local -a bases=()
    local b
    while IFS= read -r b; do
        [[ -n "${b}" ]] && bases+=("${b}")
    done < <(git merge-base --all "refs/remotes/${remote_name}/${PT_BASE_BRANCH}" "${local_sha}" 2>/dev/null)
    if [[ "${#bases[@]}" -ne 1 ]]; then
        _pt_err "Trusted base AMBÍGUO para '${local_sha:0:12}': merge-base com
'${remote_name}/${PT_BASE_BRANCH}' retornou ${#bases[@]} candidatos
(esperado exatamente 1). Falhando fechado."
        return 1
    fi
    echo "${bases[0]}"
}

# -----------------------------------------------------------------------------
# Auditoria do range candidato (proveniência/notes)
# -----------------------------------------------------------------------------

# F1 (#7604/#7608): a auditoria de identidade de autoria do range
# (_pt_audit_identity) foi REMOVIDA — era a terceira camada do mesmo
# invariante. Autoridades preservadas:
#   - pre-commit local (hooks/pre-commit): cada commit NASCE com o e-mail do
#     slot do worktree (bloqueia e-mail genérico e mismatch na criação);
#   - G8.3 (CI, ci-core.yml): prova que todo commit do range do PR tem autor
#     == identidade derivada da branch ia-* (CI = prova);
#   - roteamento ref↔worktree neste hook: a ref ia-<identidade>/* só pode ser
#     empurrada pelo worktree configurado com o e-mail correspondente.
# O que este hook mantém de único: proveniência (worktree notes, abaixo) e
# rewrite authority (patch-id + autoria preservada + notes, mais adiante).

# Todo commit de IA do range candidato deve carregar worktree note. Notes
# ausentes NUNCA são auto-reparadas neste hook: uma note criada no pre-push
# pelo próprio agente que está empurrando (autor e data do push, não do
# commit) não prova proveniência — o purity check consome essas notes como
# prova, então repará-las aqui seria autocertificação circular. Sem note ->
# BLOCK (fail-closed): a note só vale se existir ANTES da transição, criada
# no worktree de origem (post-commit / safe-squash).
_pt_audit_notes() {
    local range="$1" expected_email="$2" identity="$3" branch="$4"
    local missing=0 hash email subject
    while IFS= read -r hash; do
        [[ -n "${hash}" ]] || continue
        email="$(git log -1 --pretty=%ae "${hash}" 2>/dev/null || echo "")"
        [[ "${email}" != "${expected_email}" ]] && continue
        if git notes --ref="${PT_NOTES_REF}" show "${hash}" >/dev/null 2>&1; then
            continue
        fi
        subject="$(git log -1 --pretty=%s "${hash}" 2>/dev/null || echo "")"
        echo "   ❌ Commit ${hash:0:8} (${subject}) sem worktree note." >&2
        missing=$((missing + 1))
    done < <(git rev-list --no-merges "${range}" 2>/dev/null)
    if [[ "${missing}" -gt 0 ]]; then
        echo "" >&2
        echo "❌❌❌ PUSH BLOCKED: MISSING WORKTREE NOTES ❌❌❌" >&2
        echo "Notes ausentes não são auto-reparadas no pre-push: proveniência" >&2
        echo "não pode ser fabricada retrospectivamente (ADR-0060, contrato I10)." >&2
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Auditoria principal — chamada pelo hook pre-push
# -----------------------------------------------------------------------------

push_transition_audit() {
    local remote_name="${1:-origin}"
    PT_STDIN_LINES=()
    PT_AGENT_BRANCHES=()

    _pt_read_stdin || return 1
    if ! _pt_load_config; then
        _pt_err "Config do agent-guard indisponível (agent-guard-config/agent-guard.yaml).
Falhando fechado: sem config não há identidade confiável para auditar."
        return 1
    fi

    # Identidade do worktree (autor que está empurrando). SSOT do "quem".
    local author_email=""
    author_email="$(git config --worktree user.email 2>/dev/null || git config user.email 2>/dev/null || echo "")"
    local author_identity=""
    [[ -n "${author_email}" ]] && author_identity="$(_pt_identity_from_email "${author_email}")"

    local agent_tuples=0
    local lr ls rr rs class branch identity expected range trusted
    local line
    for line in "${PT_STDIN_LINES[@]}"; do
        read -r lr ls rr rs <<< "${line}"
        class=""

        # --- Roteamento explícito de refs não-branch -------------------------
        if [[ "${rr}" == refs/notes/* || "${rr}" == refs/agent-guard/* ]]; then
            # Fluxo dedicado: o push das notes é feito pelo próprio hook com
            # --no-verify. Tupla de notes no stdin de um push normal não é
            # auditada como branch de task.
            continue
        fi
        if [[ "${rr}" == refs/tags/* ]]; then
            if [[ -n "${author_identity}" ]]; then
                _pt_err "Push de tag ('${rr}') por agente ia-${author_identity}: policy
explícita — agentes não criam/alteram tags diretamente. Peça a um humano."
                return 1
            fi
            if [[ "${ls}" =~ ^0+$ ]]; then
                _pt_err "Deleção de tag ('${rr}') sem autorização. Falhando fechado."
                return 1
            fi
            continue
        fi
        if [[ "${rr}" != refs/heads/* ]]; then
            _pt_err "Ref remota não roteada ('${rr}'). Falhando fechado."
            return 1
        fi

        branch="${rr#refs/heads/}"

        # --- Deleção de branch ----------------------------------------------
        if [[ "${ls}" =~ ^0+$ ]]; then
            if [[ -n "${author_identity}" ]]; then
                _pt_err "Deleção de branch '${branch}' por agente ia-${author_identity}:
policy explícita e fail-closed — agentes não deletam branches via push."
                return 1
            fi
            _pt_err "Deleção de branch '${branch}' sem autorização. Falhando fechado."
            return 1
        fi

        # --- Branch protegida (derivada da REF enviada) -----------------------
        if _pt_is_protected "${branch}"; then
            _pt_err "Push direto para branch protegida '${branch}' (ref enviada).
Abra um Pull Request."
            return 1
        fi

        # --- Derivação de identidade da ref ----------------------------------
        identity=""
        expected=""
        if [[ "${branch}" =~ ^ia-([a-z0-9]+)/ ]]; then
            identity="${BASH_REMATCH[1]}"
            expected="$(_pt_expected_email_for "${identity}")"
            # identity × worktree mismatch
            if [[ "${author_email}" != "${expected}" ]]; then
                _pt_err "Identity × worktree mismatch: ref 'ia-${identity}/*' exige autor
'${expected}', mas o worktree está configurado com '${author_email:-<vazio>}'.
Corrija com: source .hmvip-agent-init ${identity} <papel>"
                return 1
            fi
        else
            # Branch não-ia empurrada por e-mail de agente: prefixo é obrigatório.
            if [[ -n "${author_identity}" ]]; then
                _pt_err "Agente ia-${author_identity} empurrando branch '${branch}' fora do
prefixo 'ia-${author_identity}/'. Bloqueado."
                return 1
            fi
            # Humano em branch não-ia: sem auditoria de agente nesta tupla.
            continue
        fi

        # A partir daqui: tupla de branch de agente (identity == author_identity).
        agent_tuples=$((agent_tuples + 1))
        PT_AGENT_BRANCHES+=("${branch}:${identity}")

        # --- Classificação da transição ---------------------------------------
        if [[ "${rs}" =~ ^0+$ ]]; then
            class="FIRST_PUSH"
        elif git merge-base --is-ancestor "${rs}" "${ls}" 2>/dev/null; then
            class="FAST_FORWARD"
        else
            class="REWRITE"
        fi
        PT_CLASS="${class}"; PT_BRANCH="${branch}"; PT_IDENTITY="${identity}"
        PT_EXPECTED_EMAIL="${expected}"; PT_LOCAL_SHA="${ls}"; PT_REMOTE_SHA="${rs}"

        echo "🔀 [TRANSITION] ${class} ${branch} (${identity}): ${rs:0:8} -> ${ls:0:8}"

        case "${class}" in
            FAST_FORWARD)
                range="${rs}..${ls}"
                ;;
            FIRST_PUSH|REWRITE)
                trusted="$(_pt_trusted_base "${remote_name}" "${ls}")" || return 1
                range="${trusted}..${ls}"
                ;;
        esac
        PT_CANDIDATE_RANGE="${range}"

        # --- Audits do range candidato (proveniência/notes) --------------------
        # Rodam ANTES da checagem de rewrite: o audit de notes exige que os
        # commits de IA do candidato já carreguem worktree note (proveniência),
        # que o purity check consome nos matches. Notes ausentes = BLOCK —
        # nada é auto-reparado aqui (proveniência não se fabrica no push).
        # (Auditoria de autoria do range removida na F1 — autoridade: G8.3 no
        # CI + pre-commit local; ver cabeçalho da seção de audits acima.)
        _pt_audit_notes "${range}" "${expected}" "${identity}" "${branch}" || return 1

        # --- Autorização de rewrite (BLOCK por padrão, sem exceção local) ------
        # Rebase puro COMPROVADO (patch + autoria + proveniência preservados,
        # sem ambiguidade, sem merge remoto removido) é o único rewrite
        # auto-autorizado. Remoção real de commits é BLOCK INCONDICIONAL:
        # grants locais foram removidos como autorização porque não comprovam
        # autoridade humana (a IA pode auto-concedê-los — ver ADR-0060). Até
        # existir mecanismo de autoridade verificável (chave privada fora do
        # alcance do processo / serviço externo / separação de usuário no SO /
        # artefato autenticado), rewrite destrutivo não tem caminho de allow.
        if [[ "${class}" == "REWRITE" ]]; then
            local -a purity_fail=()
            local pr_line
            while IFS= read -r pr_line; do
                [[ -n "${pr_line}" ]] && purity_fail+=("${pr_line}")
            done < <(_pt_rewrite_check_purity "${ls}" "${rs}" "${expected}" "${identity}" "${branch}")

            if [[ "${#purity_fail[@]}" -eq 0 ]]; then
                echo "   🔀 Rebase puro comprovado (patch + autoria + proveniência preservados) — autorizado."
                _pt_journal "push-rewrite-pure-authorized" "identity=${identity} branch=${branch} remote=${rs:0:12} local=${ls:0:12}"
            else
                local pf
                for pf in "${purity_fail[@]}"; do
                    case "${pf%% *}" in
                        MERGE_REMOVED)
                            echo "   ❌ Merge commit remoto ${pf#MERGE_REMOVED } desapareceu no candidato — remoção real." >&2
                            ;;
                        REMOVED)
                            local pr_sha="${pf#REMOVED }"
                            local pr_email pr_slot
                            pr_email="$(git log -1 --pretty=%ae "${pr_sha}" 2>/dev/null || echo "?")"
                            pr_slot="$(_pt_identity_from_email "${pr_email}")"
                            if [[ -n "${pr_slot}" && "${pr_slot}" != "${identity}" ]]; then
                                echo "   ❌ Commit ${pr_sha:0:8} do slot '${pr_slot}' (autor '${pr_email}') removido sem correspondência comprovada." >&2
                            else
                                echo "   ❌ Commit ${pr_sha:0:8} (autor '${pr_email}') removido sem correspondência comprovada." >&2
                            fi
                            ;;
                        AMBIGUOUS)
                            echo "   ❌ Mapeamento ambíguo: ${pf} — não é possível comprovar qual candidato substitui o remoto." >&2
                            ;;
                        AUTHOR_CHANGED)
                            echo "   ❌ Autoria divergente no match: ${pf} — mesmo patch com autor diferente não preserva proveniência." >&2
                            ;;
                        PROVENANCE_LOST)
                            echo "   ❌ Proveniência perdida: commit ${pf#PROVENANCE_LOST } sem worktree note de identity/branch." >&2
                            ;;
                        *)
                            echo "   ❌ ${pf}" >&2
                            ;;
                    esac
                done
                echo "" >&2
                echo "❌❌❌ PUSH BLOCKED: REWRITE DESTRUTIVO NÃO AUTORIZADO ❌❌❌" >&2
                echo "Branch: ${branch} | remote ${rs:0:12} -> local ${ls:0:12}" >&2
                echo "Rebase puro (conteúdo, autoria e proveniência preservados) continua liberado." >&2
                echo "Remoção real de commits exige autoridade humana VERIFICÁVEL, que ainda" >&2
                echo "não existe no ecossistema (gap formal — ADR-0060). Nenhum artefato local" >&2
                echo "(grant, solicitação, CLI) é aceito como autorização: a IA pode" >&2
                echo "auto-concedê-los. Para destruir histórico, peça a um humano com" >&2
                echo "acesso ao repositório (force push direto)." >&2
                _pt_journal "push-rewrite-blocked" "identity=${identity} branch=${branch} remote=${rs:0:12} local=${ls:0:12} motivos=$(printf '%s;' "${purity_fail[@]}")"
                return 1
            fi
        fi
    done

    if [[ "${#PT_AGENT_BRANCHES[@]}" -gt 0 ]]; then
        echo "✅ [TRANSITION] ${#PT_AGENT_BRANCHES[@]} tupla(s) de agente auditada(s)."
    fi
    return 0
}
