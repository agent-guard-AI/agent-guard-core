#!/usr/bin/env bash
#
# agent-guard-core — Task Lifecycle Service
#
# Gerencia o ciclo de vida de tarefas em notas de slot estruturadas com
# YAML frontmatter. Preserva notas legadas em markdown livre via fallback.
#
# Uso (sourced):
#   source "${AGENT_GUARD_DIR}/src/task-lifecycle.sh"
#   _task_read_frontmatter "${note_path}"
#   _task_write_note "${note_path}" "${metadata_yaml}" "${body}"

# Guard against double-sourcing (readonly arrays cannot be redefined).
if [[ -n "${_TASK_LIFECYCLE_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_TASK_LIFECYCLE_LOADED=1

set -euo pipefail

# Resolve o diretório deste script mesmo quando sourcado.
_TASK_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve a usable Python interpreter cross-platform.
AG_PYTHON="$(bash "${_TASK_CORE_DIR}/bin/agent-guard-python" 2>/dev/null || echo "python3")"
export AG_PYTHON

# ---------------------------------------------------------------------------
# Configuração e constantes
# ---------------------------------------------------------------------------

# Estados válidos de task, em ordem de progresso.
readonly _TASK_VALID_STATES=("planning" "coding" "review" "blocked" "done")

# Transições permitidas: estado_atual -> estado_destino.
# "done" só é alcançável manualmente ou após validação de worktree/PRs.
_task_allowed_transition() {
    local current="${1:-}"
    local next="${2:-}"
    # Estado vazio ou desconhecido é tratado como legacy.
    if [[ -z "${current}" || "${current}" == "legacy" ]]; then
        return 0
    fi
    case "${current}:${next}" in
        planning:coding|planning:blocked|coding:review|coding:blocked|review:done|review:blocked|review:coding|blocked:coding|blocked:review|blocked:done)
            return 0
            ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Helpers de caminho
# ---------------------------------------------------------------------------

_task_get_repo_root() {
    local repo_root="${1:-}"
    if [[ -n "${repo_root}" ]]; then
        echo "${repo_root}"
        return 0
    fi
    if [[ -n "${AGENT_GUARD_REPO_ROOT:-}" ]]; then
        echo "${AGENT_GUARD_REPO_ROOT}"
        return 0
    fi
    local git_common_dir
    git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "${git_common_dir}" = /* ]]; then
        cd "$(dirname "${git_common_dir}")" && pwd
    else
        cd "${_TASK_CORE_DIR}/${git_common_dir}/.." && pwd
    fi
}

_task_note_path() {
    local identity="${1:-}"
    local repo_root
    repo_root="$(_task_get_repo_root "${2:-}")"
    echo "${repo_root}/.agent-guard/tasks/${identity}.md"
}

# ---------------------------------------------------------------------------
# Parser YAML frontmatter
# ---------------------------------------------------------------------------

# Extrai o frontmatter YAML e o corpo markdown de uma nota.
# Escreve frontmatter e body em arquivos temporários e imprime os caminhos
# separados por newline (frontmatter primeiro, depois body).
#
# Uso: _task_split_note <note_path>
_task_split_note() {
    local note_path="${1:-}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    if [[ ! -f "${note_path}" ]]; then
        touch "${tmp_dir}/frontmatter" "${tmp_dir}/body"
        echo "${tmp_dir}/frontmatter"
        echo "${tmp_dir}/body"
        return 0
    fi

    "${AG_PYTHON}" - <<'PY' "${note_path}" "${tmp_dir}"
import sys
path = sys.argv[1]
tmp_dir = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

if content.startswith("---\n"):
    end = content.find("\n---\n", 4)
    if end != -1:
        frontmatter = content[4:end]
        body = content[end + 5:]
    else:
        frontmatter = ""
        body = content
else:
    frontmatter = ""
    body = content

with open(f"{tmp_dir}/frontmatter", "w", encoding="utf-8") as f:
    f.write(frontmatter)
with open(f"{tmp_dir}/body", "w", encoding="utf-8") as f:
    f.write(body)
print(f"{tmp_dir}/frontmatter")
print(f"{tmp_dir}/body")
PY
}

# Lê o frontmatter de uma nota e retorna JSON com os campos normalizados.
# Se a nota não tiver frontmatter, retorna state=legacy e preserva o corpo.
_task_read_frontmatter() {
    local note_path="${1:-}"

    if [[ ! -f "${note_path}" ]]; then
        echo '{"state":"legacy","body":""}'
        return 0
    fi

    "${AG_PYTHON}" - <<'PY' "${note_path}"
import sys, json, yaml
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

frontmatter = ""
body = content
if content.startswith("---\n"):
    end = content.find("\n---\n", 4)
    if end != -1:
        frontmatter = content[4:end]
        body = content[end + 5:]

if not frontmatter:
    print(json.dumps({"state": "legacy", "body": body}))
    sys.exit(0)

try:
    data = yaml.safe_load(frontmatter) or {}
except Exception:
    data = {}

# Normaliza: suporta tanto top-level flat quanto aninhado em task:
if isinstance(data, dict) and "task" in data and isinstance(data["task"], dict):
    task = data["task"]
else:
    task = data if isinstance(data, dict) else {}

result = {
    "id": str(task.get("id", "")),
    "state": str(task.get("state", "legacy")),
    "mode": str(task.get("mode", "manual")),
    "topic": str(task.get("topic", "")),
    "goal": str(task.get("goal", "")),
    "branch": str(task.get("branch", "")),
    "prs": task.get("prs", []),
    "next_step": str(task.get("next_step", "")),
    "alerts": task.get("alerts", []),
    "blocked_reason": str(task.get("blocked_reason", "")),
    "created_at": str(task.get("created_at", "")),
    "updated_at": str(task.get("updated_at", "")),
    "body": body,
}

# Garante que prs e alerts sejam listas.
if not isinstance(result["prs"], list):
    result["prs"] = []
if not isinstance(result["alerts"], list):
    result["alerts"] = []

print(json.dumps(result))
PY
}

# Retorna apenas o valor de um campo do frontmatter.
_task_get_field() {
    local note_path="${1:-}"
    local field="${2:-}"
    local json
    json="$(_task_read_frontmatter "${note_path}")"
    "${AG_PYTHON}" - <<'PY' "${json}" "${field}"
import sys, json
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}
value = data.get(sys.argv[2], "")
if isinstance(value, list):
    print(",".join(str(x) for x in value))
elif value is None:
    print("")
else:
    print(str(value))
PY
}

# ---------------------------------------------------------------------------
# Validação de schema e estados
# ---------------------------------------------------------------------------

_task_state_is_valid() {
    local state="${1:-}"
    local s
    for s in "${_TASK_VALID_STATES[@]}"; do
        if [[ "${s}" == "${state}" ]]; then
            return 0
        fi
    done
    return 1
}

_task_validate_state() {
    local state="${1:-}"
    if ! _task_state_is_valid "${state}"; then
        echo "❌ Estado inválido: '${state}'. Estados válidos: $(_task_join_array ', ' "${_TASK_VALID_STATES[@]}")" >&2
        return 1
    fi
    return 0
}

_task_join_array() {
    local sep="${1}"
    shift
    local out=""
    local first=1
    for item in "$@"; do
        if [[ "${first}" -eq 1 ]]; then
            out="${item}"
            first=0
        else
            out="${out}${sep}${item}"
        fi
    done
    echo "${out}"
}

# ---------------------------------------------------------------------------
# Escrita de notas estruturadas
# ---------------------------------------------------------------------------

# Faz backup da nota legada antes da primeira escrita estruturada.
_task_backup_legacy_note() {
    local note_path="${1:-}"
    if [[ ! -f "${note_path}" ]]; then
        return 0
    fi

    local has_frontmatter
    has_frontmatter="$(_task_has_frontmatter "${note_path}")"

    # Só faz backup se ainda não tiver frontmatter.
    if [[ "${has_frontmatter}" == "true" ]]; then
        return 0
    fi

    local backup_path
    backup_path="${note_path}.legacy.$(date +%Y%m%d%H%M%S)"
    cp -p "${note_path}" "${backup_path}"
    chmod 600 "${backup_path}"
}

_task_has_frontmatter() {
    local note_path="${1:-}"
    "${AG_PYTHON}" - <<'PY' "${note_path}"
import sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
except Exception:
    print("false")
    sys.exit(0)

if content.startswith("---\n"):
    end = content.find("\n---\n", 4)
    if end != -1:
        frontmatter = content[4:end]
        print("true" if frontmatter.strip() else "false")
        sys.exit(0)
print("false")
PY
}

# Escreve uma nota com YAML frontmatter + corpo markdown.
# Parâmetros:
#   $1: note_path
#   $2: metadata JSON (será convertida para YAML aninhado sob `task:`)
#   $3: body markdown
_task_write_note() {
    local note_path="${1:-}"
    local metadata_json="${2:-}"
    local body="${3:-}"

    if [[ -z "${note_path}" ]]; then
        echo "❌ _task_write_note: note_path é obrigatório" >&2
        return 1
    fi

    # Garante diretório e permissões restritas.
    local note_dir
    note_dir="$(dirname "${note_path}")"
    mkdir -p "${note_dir}"
    chmod 700 "${note_dir}"

    _task_backup_legacy_note "${note_path}"

    local yaml
    yaml="$(_task_json_to_yaml "${metadata_json}")"

    {
        echo "---"
        echo "${yaml}"
        echo "---"
        echo "${body}"
    } > "${note_path}"

    chmod 600 "${note_path}"
    return 0
}

_task_json_to_yaml() {
    local json="${1:-}"
    "${AG_PYTHON}" - <<'PY' "${json}"
import sys, json, yaml
try:
    data = json.loads(sys.argv[1]) if sys.argv[1] else {}
except Exception:
    data = {}
# Garante ordem estável de chaves.
ordered = {k: data.get(k, "") for k in [
    "id", "state", "mode", "topic", "goal", "branch",
    "prs", "next_step", "alerts", "blocked_reason",
    "created_at", "updated_at"
]}
# Remove campos vazios por padrão, exceto state.
clean = {}
for k, v in ordered.items():
    if k == "state" or v:
        clean[k] = v
print(yaml.safe_dump({"task": clean}, sort_keys=False, allow_unicode=True))
PY
}

# ---------------------------------------------------------------------------
# Helpers de validação para transição -> done
# ---------------------------------------------------------------------------

# Verifica se o worktree associado à nota está limpo (sem mudanças pendentes).
# Retorna 0 se limpo ou se não for possível determinar (fail-soft).
_task_worktree_is_clean() {
    local note_path="${1:-}"
    local repo_root="${2:-}"
    if [[ -z "${repo_root}" ]]; then
        repo_root="$(_task_get_repo_root "")"
    fi

    local identity
    identity="$(basename "${note_path}" .md 2>/dev/null || echo "")"
    [[ -n "${identity}" ]] || return 0

    local worktree
    worktree="${repo_root}/hmvip-ia-${identity}"
    if [[ ! -e "${worktree}/.git" ]]; then
        # Fallback: tenta ler do frontmatter.
        local branch
        branch="$(_task_get_field "${note_path}" "branch")"
        if [[ -n "${branch}" ]]; then
            worktree="${repo_root}/hmvip-ia-${identity}"
        fi
    fi

    if [[ ! -e "${worktree}/.git" ]]; then
        return 0
    fi

    local dirty
    dirty="$(git -C "${worktree}" status --porcelain 2>/dev/null || true)"
    if [[ -n "${dirty}" ]]; then
        return 1
    fi
    return 0
}

# Lista PRs abertos da identidade. Retorna linhas "number title" ou vazio.
#
# Hermeticidade: em testes, exporte AGENT_GUARD_PR_PROVIDER para um comando
# que retorne as linhas de PR (ou vazio). O provider recebe <identity> <repo_slug>
# como argumentos. Quando nao definido, fallback para `gh pr list`.
_task_open_prs_for_identity() {
    local identity="${1:-}"
    local repo_root="${2:-}"
    if [[ -z "${repo_root}" ]]; then
        repo_root="$(_task_get_repo_root "")"
    fi

    local provider="${AGENT_GUARD_PR_PROVIDER:-}"
    local repo_slug="${AGENT_GUARD_REPO_SLUG:-hmvip-org/hmvip}"

    if [[ -n "${provider}" ]]; then
        # Provider injetado: passa identidade e repo slug, ignora erros.
        (${provider} "${identity}" "${repo_slug}" 2>/dev/null) || true
        return 0
    fi

    if ! command -v gh >/dev/null 2>&1; then
        return 0
    fi
    local worktree
    worktree="${repo_root}/hmvip-ia-${identity}"
    if [[ ! -e "${worktree}/.git" ]]; then
        worktree="${repo_root}"
    fi
    (cd "${worktree}" 2>/dev/null && gh pr list --repo "${repo_slug}" --state open --limit 100 \
        --json number,title,headRefName \
        --jq ".[] | select(.headRefName | startswith(\"ia-${identity}/\")) | \"\(.number) \\t\(.title)\"" 2>/dev/null) || true
}

# Valida se é seguro marcar a task como done.
# Retorna 0 se worktree limpo e sem PRs abertos; 1 caso contrário.
_task_validate_done() {
    local note_path="${1:-}"
    local identity="${2:-}"
    local repo_root="${3:-}"

    if ! _task_worktree_is_clean "${note_path}" "${repo_root}"; then
        echo "❌ Worktree sujo. Commit/stash antes de marcar como done." >&2
        return 1
    fi

    local pr_lines
    pr_lines="$(_task_open_prs_for_identity "${identity}" "${repo_root}")"
    if [[ -n "${pr_lines}" ]]; then
        local pr_count
        pr_count="$(printf '%s\n' "${pr_lines}" | grep -c . || true)"
        echo "❌ ${pr_count} PR(s) aberto(s) de ia-${identity}/*:" >&2
        printf '%s\n' "${pr_lines}" | sed 's/^/   /' >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Transições de estado
# ---------------------------------------------------------------------------

# Transiciona o estado de uma task, validando a transição.
# Parâmetros:
#   $1: note_path
#   $2: new_state
#   $3: reason (opcional)
#   $4: identity (opcional, necessário para validar -> done)
#   $5: repo_root (opcional)
_task_set_state() {
    local note_path="${1:-}"
    local new_state="${2:-}"
    local reason="${3:-}"
    local identity="${4:-}"
    local repo_root="${5:-}"

    if [[ ! -f "${note_path}" ]]; then
        echo "❌ Nota não encontrada: ${note_path}" >&2
        return 1
    fi

    if ! _task_validate_state "${new_state}"; then
        return 1
    fi

    local current_state
    current_state="$(_task_get_field "${note_path}" "state")"
    current_state="${current_state:-legacy}"

    if [[ "${current_state}" == "done" && "${new_state}" != "done" ]]; then
        echo "❌ Transição proibida: done -> ${new_state}. Use --force se realmente necessário." >&2
        return 1
    fi

    if ! _task_allowed_transition "${current_state}" "${new_state}"; then
        echo "❌ Transição não permitida: ${current_state} -> ${new_state}" >&2
        return 1
    fi

    # Para -> done, valida worktree limpo e PRs abertos.
    if [[ "${new_state}" == "done" ]]; then
        if [[ -z "${identity}" ]]; then
            identity="$(basename "${note_path}" .md 2>/dev/null || echo "")"
        fi
        if ! _task_validate_done "${note_path}" "${identity}" "${repo_root}"; then
            return 1
        fi
    fi

    local json
    json="$(_task_read_frontmatter "${note_path}")"

    # Atualiza campos.
    local updated
    updated="$(_task_update_metadata "${json}" "state" "${new_state}")"
    updated="$(_task_update_metadata "${updated}" "updated_at" "$(date -Iseconds)")"
    if [[ -n "${reason}" ]]; then
        if [[ "${new_state}" == "blocked" ]]; then
            updated="$(_task_update_metadata "${updated}" "blocked_reason" "${reason}")"
        fi
    fi

    local body
    body="$(_task_get_field "${note_path}" "body")"

    _task_write_note "${note_path}" "${updated}" "${body}"
    return 0
}

_task_update_metadata() {
    local json="${1:-}"
    local key="${2:-}"
    local value="${3:-}"
    "${AG_PYTHON}" - <<'PY' "${json}" "${key}" "${value}"
import sys, json
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}
# If the value is valid JSON (array/object/bool/null/number), store it as-is;
# otherwise store it as a string. This allows fields like "prs" and "alerts"
# to remain arrays while keeping plain text fields as strings.
try:
    parsed = json.loads(sys.argv[3])
except Exception:
    parsed = sys.argv[3]
data[sys.argv[2]] = parsed
print(json.dumps(data))
PY
}

# ---------------------------------------------------------------------------
# Criação de task
# ---------------------------------------------------------------------------

_task_create() {
    local identity="${1:-}"
    local topic="${2:-}"
    local branch="${3:-}"
    local note_path="${4:-}"
    if [[ -z "${note_path}" ]]; then
        note_path="$(_task_note_path "${identity}")"
    fi

    local now
    now="$(date -Iseconds)"

    local id
    id="$(echo "${topic}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')"

    local metadata
    metadata="$("${AG_PYTHON}" - <<'PY' "${id}" "${topic}" "${branch}" "${now}"
import sys, json
print(json.dumps({
    "id": sys.argv[1],
    "state": "planning",
    "mode": "manual",
    "topic": sys.argv[2],
    "goal": "",
    "branch": sys.argv[3],
    "prs": [],
    "next_step": "",
    "alerts": [],
    "blocked_reason": "",
    "created_at": sys.argv[4],
    "updated_at": sys.argv[4],
}))
PY
)"

    local body=""
    if [[ -f "${note_path}" ]]; then
        body="$(_task_get_field "${note_path}" "body")"
    fi

    _task_write_note "${note_path}" "${metadata}" "${body}"
    return 0
}
