# F0-F S3 — VERIFICATION register (Agent Guard) — v3 READ-ONLY (derivação ao vivo).
# ==============================================================================
# Guard against double-sourcing.
if [[ -n "${_VERIFY_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_VERIFY_SH_LOADED=1

set -euo pipefail

_VERIFY_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# verify.sh depende do CLAIM (S2) apenas para resolução de worktrees/run dirs.
if [[ -z "${_CLAIM_SH_LOADED:-}" ]]; then
    # shellcheck source=/dev/null
    source "${_VERIFY_CORE_DIR}/src/claim.sh"
fi

# ---------------------------------------------------------------------------
# MODELO VIGENTE (pós-#7609 / OWNER DECISION 2026-09-13):
#
# A obrigatoriedade universal de revisão manual INDEPENDENT_REVIEW para PRs
# CRITICAL foi REMOVIDA (causava loops excessivos de governança). Autoridade
# de integração: GitHub required checks + CI determinístico + Merge Queue.
# O G1 permanece somente como CLASSIFICAÇÃO/METADATA OBSERVACIONAL de risco
# (pr_classify_files_critical) — não concede nem nega VERIFIED.
#
# VERIFIED é DERIVADO (READ-ONLY) de:
#   - TASK/run ativo (semântica canônica S2, _claim_active_run_dir);
#   - manifest verification.md (declaration do executor — NÃO é verdict) +
#     evidence/ real, não vazia, TRACKED e byte-idêntica ao HEAD vivo;
#   - HEAD vivo da PR (GitHub) + disponibilidade local (fail-closed);
#   - required checks do ruleset APLICÁVEL À BASE REF da PR (conditions
#     include/exclude avaliadas, enforcement active, ~DEFAULT_BRANCH),
#     INCLUINDO o job `Agent Governance` INTEIRO (zero exclusão);
#   - boundaries (condição #5) e rollback quando o PR toca código/runtime.
#
# verification.md é manifest/evidence declaration: usa prepared_by/
# prepared_at. O estado final VERIFIED/REJECTED/UNKNOWN é DERIVADO pelo
# control plane — nenhum executor declara a própria verificação independente.
#
# Não depende de attestation manual, comentário de PR, reviewer_identity ou
# reviewed_head_sha. Push novo reavalia naturalmente (HEAD vivo + checks do
# novo HEAD). Sem mutação Git em nenhuma operação (histórico = Git history +
# GitHub checks). Ver addendum: f0f-s3-verification-addendum-20260913.md.
#
# Uso (READ-ONLY):
#   agent-guard verify <task_id> --pr <N> [--run-seq NN]
#   agent-guard verify --check <task_id> --pr <N> [--run-seq NN]
#   agent-guard verify --pending            # visão local informational
#
# Hermeticidade: testes REDEFINEM as funções `_vgh_*` de I/O no processo
# (monkeypatch inacessível pelo CLI operacional). Nenhuma env var substitui
# GitHub/G1/HEAD/checks.
# ---------------------------------------------------------------------------

_verify_usage() {
    cat >&2 <<'EOF'
Uso (READ-ONLY — nenhuma operação modifica o worktree):
  agent-guard verify <task_id> --pr <N> [--run-seq NN]
  agent-guard verify --check <task_id> --pr <N> [--run-seq NN]
  agent-guard verify --pending

Deriva o estado VERIFIED ao vivo de GitHub/Git local:
  - verification.md + evidence/ devem estar COMMITADOS no HEAD final da PR
    (estado durável em Git antes da verificação pelo CI determinístico);
  - required checks efetivos = UNIÃO de rulesets aplicáveis à base + branch
    protection da base (autoridade GitHub); push novo reavalia o novo HEAD.
EOF
}

# ---------------------------------------------------------------------------
# Fonte canônica G1 (classificador puro, uso observacional). Fail-closed.
# ---------------------------------------------------------------------------

_verify_source_classifier() {
    local worktree="${1:-}"
    local g1="${worktree}/.github/scripts/pr-critical-review-gate.sh"
    if [[ ! -f "${g1}" ]]; then
        echo "❌ G1 canônico não encontrado em ${g1}. Fail-closed." >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "${g1}"
    if ! command -v pr_classify_files_critical >/dev/null 2>&1; then
        echo "❌ G1 canônico sem pr_classify_files_critical. Fail-closed." >&2
        return 1
    fi
    if ! command -v pr_classify_files_critical_safe >/dev/null 2>&1; then
        echo "❌ G1 canônico sem pr_classify_files_critical_safe. Fail-closed." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# I/O GitHub — funções `_vgh_*` são o ÚNICO ponto de I/O. Operação real via
# gh; testes herméticos REDEFINEM estas funções no processo (monkeypatch
# in-process). Nenhuma env var operacional substitui GitHub/G1/HEAD/checks.
# Todas as coleções paginam por completo (padrão --paginate do G1: o jq roda
# por página e o output agregado é TSV/filename — nunca JSON concatenado).
# ---------------------------------------------------------------------------

_vgh_owner_repo() {
    local remote owner repo
    remote="$(git remote get-url origin 2>/dev/null || true)"
    owner="$(sed -E 's#.*github.com[:/]([^/]+)/([^/.]+).*#\1#' <<< "${remote}")"
    repo="$(sed -E 's#.*github.com[:/]([^/]+)/([^/.]+).*#\2#' <<< "${remote}")"
    if [[ -z "${owner}" || -z "${repo}" || "${owner}" == *"//"* ]]; then
        echo "❌ remote origin inválido ('${remote}'). Fail-closed." >&2
        return 1
    fi
    echo "${owner} ${repo}"
}

# Meta do PR: campos separados por \x1f (não-whitespace — IFS whitespace
# colapsaria campos vazios): head_sha, head_ref, author_login, labels
# (space-sep), base_ref (required checks se aplicam à BASE da PR).
_vgh_pr_meta() {
    local pr="${1:-}"
    local orc
    orc="$(_vgh_owner_repo)"
    gh api "repos/${orc% *}/${orc#* }/pulls/${pr}" \
        --jq '[.head.sha, .head.ref, .user.login, ([.labels[].name] | join(" ")), .base.ref] | join("\u001f")' 2>/dev/null \
        || { echo "❌ pulls/${pr} indisponível. Fail-closed." >&2; return 1; }
}

# Check-runs de um SHA como TSV name \t conclusion_lowercase \t url —
# paginado por completo (conclusions reais da API são minúsculas).
_vgh_checks_tsv() {
    local pr="${1:-}" sha="${2:-}"
    local orc
    orc="$(_vgh_owner_repo)"
    gh api "repos/${orc% *}/${orc#* }/commits/${sha}/check-runs?per_page=100" \
        --paginate --jq '.check_runs[] | [.name, ((.conclusion // "pending") | ascii_downcase), .html_url] | @tsv' 2>/dev/null \
        || { echo "❌ check-runs de ${sha} indisponível. Fail-closed." >&2; return 1; }
}

# Changed files do PR (um path por linha, paginado).
_vgh_pr_files() {
    local pr="${1:-}"
    local orc
    orc="$(_vgh_owner_repo)"
    gh api "repos/${orc% *}/${orc#* }/pulls/${pr}/files?per_page=100" \
        --paginate --jq '.[].filename' 2>/dev/null \
        || { echo "❌ files/${pr} indisponível. Fail-closed." >&2; return 1; }
}

# Required checks canônicos: ruleset GitHub (autoridade), MAS apenas dos
# rulesets APLICÁVEIS À BASE REF da PR (conditions.ref_name include/exclude,
# enforcement active, ~DEFAULT_BRANCH). Nunca exigir checks de release/*,
# main ou branches futuras quando a base é develop.
_vgh_default_branch() {
    local orc
    orc="$(_vgh_owner_repo)"
    gh api "repos/${orc% *}/${orc#* }" --jq '.default_branch' 2>/dev/null \
        || { echo "❌ default_branch indisponível. Fail-closed." >&2; return 1; }
}

_vgh_ruleset_ids() {
    local orc
    orc="$(_vgh_owner_repo)"
    gh api --paginate "repos/${orc% *}/${orc#* }/rulesets" \
        --jq '.[] | select(.target=="branch" and .enforcement=="active") | .id' 2>/dev/null \
        || { echo "❌ rulesets indisponível. Fail-closed." >&2; return 1; }
}

_vgh_ruleset_detail() {
    local id="${1:-}"
    local orc
    orc="$(_vgh_owner_repo)"
    gh api "repos/${orc% *}/${orc#* }/rulesets/${id}" 2>/dev/null \
        || { echo "❌ ruleset ${id} indisponível. Fail-closed." >&2; return 1; }
}

# Avaliador puro de aplicabilidade: recebe base_ref (lógico, ex. "develop"),
# default_branch e o JSON do ruleset (stdin); emite os contexts de
# required_status_checks se o ruleset se aplicar à base, nada caso contrário.
# Fail-closed no JSON. Patterns normais casam contra full_ref
# ("refs/heads/<base_ref>") — formato real das conditions.ref_name do
# GitHub; "~DEFAULT_BRANCH" compara base_ref LÓGICO com default_branch.
_vgh_ruleset_contexts() {
    local base_ref="${1:-}" default_branch="${2:-}"
    python3 -c '
import fnmatch, json, sys
base_ref, default_branch = sys.argv[1], sys.argv[2]
full_ref = "refs/heads/" + base_ref
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if d.get("enforcement") != "active":
    sys.exit(0)
cond = (d.get("conditions") or {}).get("ref_name") or {}
includes = cond.get("include") or ["~DEFAULT_BRANCH"]
excludes = cond.get("exclude") or []
def matches(pat):
    if pat == "~DEFAULT_BRANCH":
        return base_ref == default_branch
    return fnmatch.fnmatchcase(full_ref, pat)
if not any(matches(p) for p in includes):
    sys.exit(0)
if any(matches(p) for p in excludes):
    sys.exit(0)
for rule in d.get("rules") or []:
    if rule.get("type") == "required_status_checks":
        for rc_ in (rule.get("parameters") or {}).get("required_status_checks") or []:
            ctx = rc_.get("context")
            if ctx:
                print(ctx)
' "${base_ref}" "${default_branch}"
}

# Contexts de required_status_checks da BRANCH PROTECTION da base (resumo
# efetivo, mesmo quando o endpoint administrativo /protection não está
# acessível). Erro de API => fail-closed; proteção ausente => vazio (zero
# contexts, sem erro — a autoridade ruleset ainda se aplica).
_vgh_branch_protection_contexts() {
    local base_ref="${1:-}"
    local orc
    orc="$(_vgh_owner_repo)"
    gh api "repos/${orc% *}/${orc#* }/branches/${base_ref}" \
        --jq '.protection.required_status_checks.contexts[]?' 2>/dev/null \
        || { echo "❌ branch protection de ${base_ref} indisponível. Fail-closed." >&2; return 1; }
}

# Uso: _vgh_required_checks <base_ref> — um required check por linha.
# AUTORIDADE EFETIVA COMPLETA = UNIÃO de:
#   A. required_status_checks dos rulesets branch aplicáveis à base;
#   B. required_status_checks da branch protection da base.
# (ex.: develop = 5 do ruleset "Proteção Básica" + Fresh Install Smoke da
# branch protection = 6 contexts efetivos). Nunca hardcodar nomes.
_vgh_required_checks() {
    local base_ref="${1:-}"
    [[ -n "${base_ref}" ]] || { echo "❌ base_ref vazio. Fail-closed." >&2; return 1; }
    local db ids id detail ctxs bp out="" found=0
    db="$(_vgh_default_branch)" || return 1
    ids="$(_vgh_ruleset_ids)" || return 1
    [[ -n "${ids}" ]] || { echo "❌ nenhum ruleset de branch ativo. Fail-closed." >&2; return 1; }
    while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        detail="$(_vgh_ruleset_detail "${id}")" || return 1
        ctxs="$(_vgh_ruleset_contexts "${base_ref}" "${db}" <<< "${detail}")" || {
            echo "❌ ruleset ${id} com JSON inválido. Fail-closed." >&2; return 1;
        }
        if [[ -n "${ctxs}" ]]; then
            out="${out}${ctxs}"$'\n'
            found=1
        fi
    done <<< "${ids}"
    bp="$(_vgh_branch_protection_contexts "${base_ref}")" || return 1
    if [[ -n "${bp}" ]]; then
        out="${out}${bp}"$'\n'
        found=1
    fi
    if [[ "${found}" -eq 0 ]]; then
        echo "❌ nenhuma autoridade de required checks aplicável à base ${base_ref}. Fail-closed." >&2
        return 1
    fi
    printf '%s' "${out}" | sort -u
}

# ---------------------------------------------------------------------------
# Resolução local
# ---------------------------------------------------------------------------

_verify_resolve_run_dir() {
    local task_id="${1:-}"
    local run_seq="${2:-}"
    local worktree
    worktree="$(_claim_worktree_root)"
    if [[ -z "${worktree}" ]]; then
        return 1
    fi
    local base="${worktree}/.kiro/runs/${task_id}"
    if [[ -n "${run_seq}" ]]; then
        if [[ -d "${base}/${run_seq}" ]]; then
            echo "${base}/${run_seq}"
            return 0
        fi
        return 1
    fi
    local best="" d
    local nullglob_was_off=1
    shopt -q nullglob && nullglob_was_off=0
    shopt -s nullglob
    local dirs=("${base}"/*/)
    if (( nullglob_was_off )); then shopt -u nullglob; else shopt -s nullglob; fi
    for d in "${dirs[@]}"; do
        [[ -f "${d}claim.md" ]] || continue
        best="${d%/}"
    done
    [[ -n "${best}" ]] && echo "${best}"
}

# Arquivo existe no worktree, é TRACKED no head vivo e é byte-idêntico ao
# blob desse head. rc=0 válido; rc=1 violação (untracked/dirty/ausente no head).
_verify_file_at_head() {
    local abs_path="${1:-}" head="${2:-}"
    [[ -f "${abs_path}" ]] || return 1
    git cat-file -e "${head}^{commit}" 2>/dev/null || return 1
    local rel blob wt_blob
    rel="$(git -C "$(dirname "${abs_path}")" rev-parse --show-prefix 2>/dev/null || true)"
    rel="${rel}$(basename "${abs_path}")"
    git cat-file -e "${head}:${rel}" 2>/dev/null || return 1
    blob="$(git rev-parse "${head}:${rel}" 2>/dev/null || true)"
    wt_blob="$(git hash-object "${abs_path}" 2>/dev/null || true)"
    [[ -n "${blob}" && "${blob}" == "${wt_blob}" ]]
}

# ---------------------------------------------------------------------------
# Parser do verification.md
# ---------------------------------------------------------------------------

_verify_parse_md() {
    local file="${1:-}"
    _V_TASK="" _V_RUNSEQ="" _V_PREPARED_BY="" _V_PREPARED_AT=""
    _V_COND_STATUS=() _V_COND_EVIDENCE=() _V_COND_ROWS=0
    [[ -f "${file}" ]] || return 2

    local line
    while IFS= read -r line; do
        case "${line}" in
            "task_id:"*)   _V_TASK="${line#task_id: }"; _V_TASK="${_V_TASK//[[:space:]]/}" ;;
            "run_seq:"*)   _V_RUNSEQ="${line#run_seq: }"; _V_RUNSEQ="${_V_RUNSEQ//[[:space:]]/}" ;;
            "prepared_by:"*)  _V_PREPARED_BY="${line#prepared_by: }" ;;
            "prepared_at:"*)  _V_PREPARED_AT="${line#prepared_at: }" ;;
        esac
    done < <(sed -n '/^---$/,/^---$/p' "${file}" | sed -n '2,$p')

    local n status evidence
    while IFS= read -r line; do
        [[ "${line}" =~ ^\|[[:space:]]*[1-6][[:space:]]*\| ]] || continue
        n="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' <<< "${line}")"
        status="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}' <<< "${line}")"
        evidence="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}' <<< "${line}")"
        [[ "${n}" =~ ^[1-6]$ ]] || continue
        _V_COND_STATUS["${n}"]="${status}"
        _V_COND_EVIDENCE["${n}"]="${evidence}"
        _V_COND_ROWS=$((_V_COND_ROWS + 1))
    done < "${file}"
    return 0
}

# ---------------------------------------------------------------------------
# Evidência REAL + TRACKED: path existe, não escapa do run dir, e é
# byte-idêntico ao blob do HEAD vivo (untracked/dirty não contam).
# ---------------------------------------------------------------------------

_verify_evidence_validate() {
    local cond="${1:-}" ev="${2:-}" run_dir="${3:-}" head="${4:-}"
    shift 4 || true
    local check_urls=("$@")

    [[ -n "${ev}" ]] || return 1
    [[ "${ev}" == *"<"* ]] && return 1
    if [[ ! "${ev}" =~ ^[[:graph:]]+$ ]]; then
        return 1  # prosa com espaços ("testei e passou") nunca conta
    fi

    # URL: só condição #2 e somente se coletada do GitHub nesta operação.
    if [[ "${ev}" =~ ^https?:// ]]; then
        [[ "${cond}" == "2" ]] || return 1
        local u
        for u in "${check_urls[@]:-}"; do
            [[ "${ev}" == "${u}" ]] && return 0
        done
        return 1
    fi

    # Hash (40/64 hex): artefato correspondente TRACKED no head vivo, NÃO
    # vazio, e com o digest conferindo quando verificável (sha256/sha1).
    if [[ "${ev}" =~ ^[0-9a-f]{40,64}$ ]]; then
        local cand
        for cand in "${run_dir}/${ev}" "${run_dir}/evidence/${ev}" "${run_dir}/evidence/${ev}.sha256"; do
            if [[ -f "${cand}" ]] && [[ -s "${cand}" ]] && _verify_file_at_head "${cand}" "${head}"; then
                local actual=""
                if [[ "${#ev}" -eq 64 ]]; then
                    actual="$(sha256sum "${cand}" 2>/dev/null | awk '{print $1}')"
                elif [[ "${#ev}" -eq 40 ]]; then
                    actual="$(sha1sum "${cand}" 2>/dev/null | awk '{print $1}')"
                fi
                if [[ -n "${actual}" ]]; then
                    [[ "${actual}" == "${ev}" ]] || return 1  # digest não confere
                fi
                return 0
            fi
        done
        return 1
    fi

    # Path: sem escape (nem por .. nem por symlink), existente, TRACKED e
    # byte-idêntico ao blob do HEAD vivo; #3 em evidence/.
    if [[ "${ev}" == *".."* ]]; then
        return 1
    fi
    local rd_real resolved
    rd_real="$(cd "${run_dir}" && pwd)"
    resolved="$(python3 -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1], sys.argv[2])))' "${rd_real}" "${ev}")"
    [[ "${resolved}" == "${rd_real}"/* ]] || return 1
    [[ -e "${resolved}" ]] || return 1
    [[ ! -L "${rd_real}/${ev}" ]] || return 1  # symlink direto proibido
    if [[ "${cond}" == "3" ]]; then
        local ev_real
        ev_real="$(cd "${run_dir}/evidence" 2>/dev/null && pwd || true)"
        [[ -n "${ev_real}" && "${resolved}" == "${ev_real}"/* ]] || return 1
    fi
    # Evidência sem conteúdo material não conta: zero-byte e whitespace-only
    # são FAIL (design: "evidência fraca sem artefato ⇒ não VERIFIED").
    [[ -s "${resolved}" ]] || return 1
    grep -q '[^[:space:]]' "${resolved}" 2>/dev/null || return 1
    _verify_file_at_head "${resolved}" "${head}" || return 1
    # *.sha256: cada entrada '<64hex><sp><sp|*>relpath' deve apontar para um
    # artefato REAL (existe, sem escape/symlink, tracked, idêntico no HEAD)
    # cujo sha256 calculado confere com o declarado. Malformed => FAIL.
    # Nunca aceitar o .sha256 só porque contém 64 hex.
    if [[ "${resolved}" == *.sha256 ]]; then
        _verify_sha256_manifest "${resolved}" "${rd_real}" "${head}" || return 1
    fi
    return 0
}

# Valida um manifest .sha256 (formato standard sha256sum) e liga cada entrada
# ao artefato real. rc=0 válido; rc=1 qualquer violação.
_verify_sha256_manifest() {
    local manifest="${1:-}" rd_real="${2:-}" head="${3:-}"
    local mdir line digest sep rpath artifact areal actual
    mdir="$(dirname "${manifest}")"
    local found=1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "$(printf '%s' "${line}" | tr -d '[:space:]')" ]] && continue
        if [[ ! "${line}" =~ ^[0-9a-f]{64}[\ \*] ]]; then
            return 1  # malformed
        fi
        digest="${line:0:64}"
        # Formato standard sha256sum, ambos os variantes:
        #   texto:   "<hash><sp><sp>name"  (sha256sum)
        #   binário: "<hash><sp>*name"     (sha256sum -b)
        # char 64 DEVE ser espaço; char 65 DEVE ser espaço ou '*'; o nome
        # começa após os dois marcadores.
        [[ "${line:64:1}" == " " ]] || return 1  # malformed
        sep="${line:65:1}"
        [[ "${sep}" == " " || "${sep}" == "*" ]] || return 1
        rpath="${line:66}"
        [[ -n "${rpath}" ]] || return 1
        [[ "${rpath}" != *".."* ]] || return 1
        if [[ "${rpath}" = /* ]]; then
            areal="${rpath}"
        else
            areal="$(python3 -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1], sys.argv[2])))' "${mdir}" "${rpath}")"
        fi
        [[ "${areal}" == "${rd_real}"/* ]] || return 1   # path escape
        [[ -f "${areal}" ]] || return 1                  # artifact inexistente
        [[ ! -L "${mdir}/${rpath}" ]] || return 1        # symlink escape
        [[ -s "${areal}" ]] || return 1                  # artifact vazio
        _verify_file_at_head "${areal}" "${head}" || return 1  # untracked/dirty
        actual="$(sha256sum "${areal}" 2>/dev/null | awk '{print $1}')"
        [[ "${actual}" == "${digest}" ]] || return 1     # digest errado
        found=0
    done < "${manifest}"
    [[ "${found}" -eq 0 ]]  # zero entradas válidas => inválido
}


# ---------------------------------------------------------------------------
# Classificação conservadora de escopo docs-only (fail-closed): qualquer
# arquivo que não seja claramente documentação => runtime/código.
# ---------------------------------------------------------------------------

_verify_is_docs_only() {
    local f
    for f in "$@"; do
        [[ -z "${f}" ]] && continue
        if [[ "${f}" =~ \.(md|markdown)$ ]]; then
            continue
        fi
        if [[ "${f}" =~ (^|/)(README|LICENSE|NOTICE|CHANGELOG|AUTHORS)(\.[a-z]+)?$ ]]; then
            continue
        fi
        return 1  # qualquer outra coisa é runtime/código
    done
    return 0
}

# ---------------------------------------------------------------------------
# verify --pending (visão local informational, read-only)
# ---------------------------------------------------------------------------

_verify_cmd_pending() {
    local worktree
    worktree="$(_claim_worktree_root)" || { echo "❌ Fora de um repositório Git." >&2; return 1; }
    local runs_root="${worktree}/.kiro/runs"
    [[ -d "${runs_root}" ]] || return 0
    local nullglob_was_off=1
    shopt -q nullglob && nullglob_was_off=0
    shopt -s nullglob
    local claims=("${runs_root}"/*/*/claim.md)
    if (( nullglob_was_off )); then shopt -u nullglob; else shopt -s nullglob; fi
    local cf run_dir task_id seq vmd_state ev_files
    for cf in "${claims[@]}"; do
        run_dir="$(dirname "${cf}")"
        task_id="$(basename "$(dirname "${run_dir}")")"
        seq="$(basename "${run_dir}")"
        vmd_state="absent"
        [[ -f "${run_dir}/verification.md" ]] || { printf 'PENDING_VERIFICATION task=%s run=%s verification.md=%s\n' "${task_id}" "${seq}" "${vmd_state}"; continue; }
        if git status --porcelain -- "${run_dir}/verification.md" 2>/dev/null | grep -q .; then
            vmd_state="dirty"
        else
            vmd_state="tracked"
        fi
        ev_files="$(find "${run_dir}/evidence" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
        printf 'RUN task=%s run=%s verification.md=%s evidence_files=%s (estado oficial: verify --check --pr)\n' \
            "${task_id}" "${seq}" "${vmd_state}" "${ev_files}"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Núcleo de derivação (READ-ONLY) — usado por `verify` e `--check`.
# Imprime linhas de detalhe + VERIFY_STATE=<estado> na última linha.
# rc=0 somente quando VERIFY_STATE=VERIFIED.
# ---------------------------------------------------------------------------

_verify_eval() {
    local task_id="${1:-}" pr="${2:-}" run_seq="${3:-}"

    local worktree
    worktree="$(_claim_worktree_root)" || { echo "ERROR=fora-de-repo"; return 1; }
    if ! _verify_source_classifier "${worktree}"; then
        echo "VERIFY_STATE=UNKNOWN"
        return 1
    fi

    # Run ativo pela semântica canônica S2 (claim.sh) — nunca escolha lexical.
    local active_dir active_rc
    active_dir="$(_claim_active_run_dir "${task_id}")" && active_rc=0 || active_rc=$?
    if [[ "${active_rc}" -eq 1 ]]; then
        echo "VERIFY_STATE=UNKNOWN (nenhum run ativo para ${task_id} — S2)"
        return 1
    fi
    if [[ "${active_rc}" -eq 2 ]]; then
        echo "VERIFY_STATE=UNKNOWN (CORRUPT: >1 run ativo para ${task_id} — S2 fail-closed)"
        return 1
    fi
    if [[ -n "${run_seq}" && "$(basename "${active_dir}")" != "${run_seq}" ]]; then
        echo "VERIFY_STATE=REJECTED (--run-seq ${run_seq} não é o run ativo $(basename "${active_dir}") — histórico/released não verifica)"
        return 1
    fi
    local run_dir="${active_dir}"
    if [[ ! -f "${run_dir}/claim.md" ]]; then
        echo "VERIFY_STATE=UNKNOWN (sem claim.md)"
        return 1
    fi

    # --- 1/2. HEAD vivo + disponibilidade local -------------------------
    local meta live_head head_ref author_login labels_raw base_ref
    meta="$(_vgh_pr_meta "${pr}")" || { echo "VERIFY_STATE=UNKNOWN"; return 1; }
    IFS=$'\x1f' read -r live_head head_ref author_login labels_raw base_ref <<< "${meta}"
    if [[ ! "${live_head}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "VERIFY_STATE=UNKNOWN (head vivo malformado)"
        return 1
    fi
    if ! git cat-file -e "${live_head}^{commit}" 2>/dev/null; then
        echo "VERIFY_STATE=UNKNOWN (HEAD vivo ${live_head} não disponível localmente — faça fetch)"
        return 1
    fi
    echo "pr=${pr} live_head=${live_head} head_ref=${head_ref} base_ref=${base_ref}"

    local niv="false"
    if grep -qw "needs-independent-verify" <<< "${labels_raw}" 2>/dev/null; then
        niv="true"
    fi

    # --- 3. Classificação de risco OBSERVACIONAL (G1 pós-#7609) ----------
    # Consome o helper canônico pr_classify_files_critical_safe (fail-closed:
    # files vazio/crash/output inválido => UNKNOWN). Risk metadata apenas —
    # NÃO é gate. A verificação independente é o CI determinístico
    # (required checks + Merge Queue); zero attestation manual.
    # classification == UNKNOWN => VERIFY_STATE=UNKNOWN (fail-closed).
    local files_raw classification
    files_raw="$(_vgh_pr_files "${pr}")" || { echo "VERIFY_STATE=UNKNOWN"; return 1; }
    classification="$(pr_classify_files_critical_safe <<< "${files_raw}")"
    if [[ "${classification}" == "UNKNOWN" ]]; then
        echo "VERIFY_STATE=UNKNOWN (classificação de risco indeterminada — fail-closed)"
        return 1
    fi
    echo "risk_metadata classification=${classification} needs_independent_verify=${niv} (observacional, não-gate)"

    # --- 4. Binding Git real (tracked + byte-idêntico ao HEAD vivo) ------
    local claim_branch
    claim_branch="$(sed -n 's/^branch: //p' "${run_dir}/claim.md" | head -n1)"
    if [[ "${claim_branch}" != "${head_ref}" ]]; then
        echo "VERIFY_STATE=REJECTED (claim.branch='${claim_branch}' != PR head.ref='${head_ref}')"
        return 1
    fi
    if ! _verify_file_at_head "${run_dir}/claim.md" "${live_head}"; then
        echo "VERIFY_STATE=REJECTED (claim.md untracked/dirty/ausente no HEAD vivo)"
        return 1
    fi
    local md="${run_dir}/verification.md"
    if ! _verify_file_at_head "${md}" "${live_head}"; then
        echo "VERIFY_STATE=REJECTED (verification.md untracked/dirty/ausente no HEAD vivo — commitar no HEAD final da PR)"
        return 1
    fi
    if ! _verify_parse_md "${md}"; then
        echo "VERIFY_STATE=REJECTED (verification.md malformado)"
        return 1
    fi
    if [[ "${_V_TASK}" != "${task_id}" || "${_V_RUNSEQ}" != "$(basename "${run_dir}")" ]]; then
        echo "VERIFY_STATE=REJECTED (frontmatter task_id/run_seq divergentes: ${_V_TASK}/${_V_RUNSEQ})"
        return 1
    fi

    # --- 6. Checks REQUIRED do ruleset APLICÁVEL À BASE (autoridade GitHub).
    # `Agent Governance` é required INTEIRO (branch ownership, agent-guard
    # validation, identity audit, worktree origin, scope collision,
    # regression guard + G1 observacional): failure/pending/missing em
    # qualquer parte => não VERIFIED. Sem exceção especial para o G1 — ele
    # é metadata de risco, e a verificação independente é o CI determinístico.
    # Push novo reavalia naturalmente: o check-runs do novo HEAD precisam
    # estar verdes; o S3 permanece fail-closed até o job completo estar verde.
    local required_raw
    if ! required_raw="$(_vgh_required_checks "${base_ref}")"; then
        echo "VERIFY_STATE=UNKNOWN"
        return 1
    fi
    local checks_tsv
    checks_tsv="$(_vgh_checks_tsv "${pr}" "${live_head}")" || { echo "VERIFY_STATE=UNKNOWN"; return 1; }
    local -a check_urls=()
    local c_name c_conclusion c_url req
    local -A seen=()
    while IFS=$'\t' read -r c_name c_conclusion c_url; do
        [[ -n "${c_name}" ]] || continue
        check_urls+=("${c_url}")
        seen["${c_name}"]="${c_conclusion:-pending}"
    done <<< "${checks_tsv}"
    local checks_ok=1 evaluated=""
    while IFS= read -r req; do
        [[ -z "${req}" ]] && continue
        if [[ -z "${seen[${req}]:-}" ]]; then
            evaluated="${evaluated} ${req}=MISSING"
            checks_ok=0
            continue
        fi
        case "${seen[${req}]}" in
            success|skipped|neutral) evaluated="${evaluated} ${req}=green" ;;
            *) evaluated="${evaluated} ${req}=${seen[${req}]}"; checks_ok=0 ;;
        esac
    done <<< "${required_raw}"
    echo "required_checks:${evaluated# }"
    if [[ "${checks_ok}" -ne 1 ]]; then
        echo "VERIFY_STATE=REJECTED (checks required técnicos não verdes/completos no HEAD vivo)"
        return 1
    fi

    # --- 7. Verification contract §6 --------------------------------------
    if [[ "${_V_COND_ROWS}" -lt 6 ]]; then
        echo "VERIFY_STATE=REJECTED (tabela de condições incompleta: ${_V_COND_ROWS}/6)"
        return 1
    fi
    local conditions_ok=1 i status evidence
    for i in 1 2 3 4 5 6; do
        status="${_V_COND_STATUS[$i]:-}"
        evidence="${_V_COND_EVIDENCE[$i]:-}"
        case "${status}" in
            PASS|FAIL) ;;
            N-A) [[ "${i}" == "6" ]] || { echo "VERIFY_STATE=REJECTED (condição ${i} N-A; só #6 admite)"; return 1; } ;;
            *) echo "VERIFY_STATE=REJECTED (condição ${i} com status inválido '${status}')"; return 1 ;;
        esac
        [[ "${status}" == "N-A" ]] && continue
        if ! _verify_evidence_validate "${i}" "${evidence}" "${run_dir}" "${live_head}" "${check_urls[@]:-}"; then
            echo "VERIFY_STATE=REJECTED (condição ${i}: evidência fraca/inexistente/untracked/dirty — '${evidence}')"
            conditions_ok=0
        fi
        [[ "${status}" == "FAIL" ]] && conditions_ok=0
    done

    # --- 8. Rollback: N-A só para escopo realmente docs-only --------------
    local -a files_arr=()
    while IFS= read -r f; do
        [[ -n "${f}" ]] && files_arr+=("${f}")
    done <<< "${files_raw}"
    if ! _verify_is_docs_only "${files_arr[@]:-}"; then
        if [[ "${_V_COND_STATUS[6]:-}" == "N-A" ]]; then
            echo "VERIFY_STATE=REJECTED (PR toca código/runtime: condição #6 (rollback) N-A inadmissível)"
            conditions_ok=0
        fi
    fi

    if [[ "${conditions_ok}" -ne 1 ]]; then
        echo "VERIFY_STATE=REJECTED (verification contract §6 não satisfeito)"
        return 1
    fi

    echo "VERIFY_STATE=VERIFIED task=${task_id} run=$(basename "${run_dir}") pr=${pr} head=${live_head} (verificador: CI determinístico + required checks)"
    return 0
}

# ---------------------------------------------------------------------------
# verify <task> --pr N  e  verify --check <task> --pr N — ambos READ-ONLY e
# derivam TODAS as autoridades ao vivo (mesmo SHA pode mudar checks/labels).
# ---------------------------------------------------------------------------

_verify_cmd_verify() {
    local task_id=""
    local pr="" run_seq=""

    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --pr) pr="${2:-}"; shift 2 ;;
            --run-seq) run_seq="${2:-}"; shift 2 ;;
            --pending) _verify_usage; return 2 ;;
            --*) echo "❌ Flag desconhecida: ${1}" >&2; _verify_usage; return 2 ;;
            *) task_id="${1}"; shift ;;
        esac
    done
    if [[ -z "${task_id}" || -z "${pr}" ]]; then
        echo "❌ Usage: agent-guard verify <task_id> --pr <N> [--run-seq NN] (READ-ONLY; HEAD vivo vem do GitHub)" >&2
        return 2
    fi
    _verify_eval "${task_id}" "${pr}" "${run_seq}"
}

_verify_cmd_check() {
    local task_id="" pr="" run_seq=""
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --pr) pr="${2:-}"; shift 2 ;;
            --run-seq) run_seq="${2:-}"; shift 2 ;;
            *) task_id="${1}"; shift ;;
        esac
    done
    if [[ -z "${task_id}" || -z "${pr}" ]]; then
        echo "❌ Usage: agent-guard verify --check <task_id> --pr <N> [--run-seq NN]" >&2
        return 2
    fi
    # --check revalida TODAS as autoridades vivas (checks/HEAD/blobs/rules):
    # por isso deriva de novo via _verify_eval — zero cache/mirror.
    _verify_eval "${task_id}" "${pr}" "${run_seq}"
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

_verify_cli_main() {
    local cmd="${1:-}"
    case "${cmd}" in
        ""|--help|-h) _verify_usage; return 2 ;;
        --pending) shift; _verify_cmd_pending "$@" ;;
        --check) shift; _verify_cmd_check "$@" ;;
        --*) echo "❌ Subcomando desconhecido: ${cmd}" >&2; _verify_usage; return 2 ;;
        *) _verify_cmd_verify "$@" ;;
    esac
}
