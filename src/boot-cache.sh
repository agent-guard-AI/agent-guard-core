#!/usr/bin/env bash
#
# boot-cache.sh — Boot cache local para sessões HMVIP (ADR-0051).
#
# Propósito: evitar re-execução total das camadas de boot quando o estado
# da sessão não mudou significativamente. O cache é isolado por worktree e
# validado por identidade, branch, TTL e hash de artefatos.
#
# Este arquivo é carregado por init.sh e também pelos hooks do Kimi Code
# (AGENT_GUARD_FUNCTIONS_ONLY=1), portanto NÃO deve ter side effects globais.

# ---------------------------------------------------------------------------
# Configurações (podem ser sobrescritas via agent-guard.yaml no futuro)
# ---------------------------------------------------------------------------
HMVIP_BOOT_CACHE_TTL_SECONDS="${HMVIP_BOOT_CACHE_TTL_SECONDS:-3600}"
HMVIP_BOOT_CACHE_P0_TTL_SECONDS="${HMVIP_BOOT_CACHE_P0_TTL_SECONDS:-900}"

# ---------------------------------------------------------------------------
# Caminho do boot-state.json dentro do worktree
# ---------------------------------------------------------------------------
_boot_state_file_path() {
    local worktree_path="${1:-${CURRENT_WORKTREE:-${WORKTREE_PATH:-$(pwd)}}}"
    printf '%s/.agent-guard/session/boot-state.json' "${worktree_path}"
}

# ---------------------------------------------------------------------------
# Garante que o diretório de sessão exista
# ---------------------------------------------------------------------------
_ensure_boot_cache_dir() {
    local worktree_path="$1"
    local session_dir="${worktree_path}/.agent-guard/session"
    if [[ ! -d "${session_dir}" ]]; then
        mkdir -p "${session_dir}" 2>/dev/null || return 1
    fi
}

# ---------------------------------------------------------------------------
# Calcula SHA256 de um arquivo
# ---------------------------------------------------------------------------
_boot_state_compute_digest() {
    local file_path="$1"
    if [[ -z "${file_path}" || ! -f "${file_path}" ]]; then
        printf ''
        return 0
    fi
    sha256sum "${file_path}" 2>/dev/null | awk '{print $1}' || printf ''
}

# ---------------------------------------------------------------------------
# Verifica se o boot-state.json existe e é fresco para as camadas solicitadas
# ---------------------------------------------------------------------------
_boot_state_load() {
    local identity="$1"
    local worktree_path="$2"
    local requested_layers="${3:-}"

    if [[ -z "${identity}" || -z "${worktree_path}" ]]; then
        return 1
    fi

    local state_file
    state_file="$(_boot_state_file_path "${worktree_path}")"
    if [[ ! -f "${state_file}" ]]; then
        return 1
    fi

    local state_json
    state_json="$(cat "${state_file}" 2>/dev/null || true)"
    if [[ -z "${state_json}" ]]; then
        return 1
    fi

    # Valida identidade e branch
    local state_identity state_branch state_timestamp state_worktree
    state_identity="$(printf '%s' "${state_json}" | ${AG_PYTHON:-python3} -c 'import sys,json; d=json.load(sys.stdin); print(d.get("identity",""))' 2>/dev/null || true)"
    state_branch="$(printf '%s' "${state_json}" | ${AG_PYTHON:-python3} -c 'import sys,json; d=json.load(sys.stdin); print(d.get("branch",""))' 2>/dev/null || true)"
    state_worktree="$(printf '%s' "${state_json}" | ${AG_PYTHON:-python3} -c 'import sys,json; d=json.load(sys.stdin); print(d.get("worktree",""))' 2>/dev/null || true)"
    state_timestamp="$(printf '%s' "${state_json}" | ${AG_PYTHON:-python3} -c 'import sys,json; d=json.load(sys.stdin); print(str(d.get("boot_timestamp",0)))' 2>/dev/null || true)"

    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || true)"

    if [[ "${state_identity}" != "${identity}" ]]; then
        return 1
    fi
    if [[ -n "${current_branch}" && "${state_branch}" != "${current_branch}" ]]; then
        return 1
    fi
    if [[ "${state_worktree}" != "${worktree_path}" ]]; then
        return 1
    fi

    # Valida TTL
    local now_epoch
    now_epoch="$(date +%s 2>/dev/null || echo 0)"
    if [[ -z "${state_timestamp}" || "${state_timestamp}" -le 0 || "$(( now_epoch - state_timestamp ))" -gt "${HMVIP_BOOT_CACHE_TTL_SECONDS}" ]]; then
        return 1
    fi

    # Valida digests dos artefatos
    local artifact_digests_json
    artifact_digests_json="$(printf '%s' "${state_json}" | ${AG_PYTHON:-python3} -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get("artifact_digests",{})))' 2>/dev/null || true)"
    if [[ -n "${artifact_digests_json}" ]]; then
        local artifact_path current_digest expected_digest
        while IFS= read -r artifact_path; do
            [[ -z "${artifact_path}" ]] && continue
            current_digest="$(_boot_state_compute_digest "${artifact_path}")"
            expected_digest="$(printf '%s' "${artifact_digests_json}" | ${AG_PYTHON:-python3} -c "import sys,json; d=json.load(sys.stdin); print(d.get(sys.argv[1],''))" "${artifact_path}" 2>/dev/null || true)"
            if [[ "${current_digest}" != "${expected_digest}" ]]; then
                return 1
            fi
        done <<< "$(printf '%s' "${artifact_digests_json}" | ${AG_PYTHON:-python3} -c 'import sys,json; d=json.load(sys.stdin); print("\n".join(d.keys()))' 2>/dev/null || true)"
    fi

    # Valida camadas solicitadas
    if [[ -n "${requested_layers}" ]]; then
        local state_layers
        state_layers="$(printf '%s' "${state_json}" | ${AG_PYTHON:-python3} -c 'import sys,json; d=json.load(sys.stdin); print(" ".join(d.get("layers",[])))' 2>/dev/null || true)"
        local layer
        for layer in ${requested_layers}; do
            if [[ " ${state_layers} " != *" ${layer} "* ]]; then
                return 1
            fi
        done
    fi

    # Exporta variáveis para as skills de boot consultarem
    export HMVIP_BOOT_CACHE_VALID="1"
    export HMVIP_BOOT_CACHE_LAYERS="$(printf '%s' "${state_json}" | ${AG_PYTHON:-python3} -c 'import sys,json; d=json.load(sys.stdin); print(" ".join(d.get("layers",[])))' 2>/dev/null || true)"
    export HMVIP_BOOT_CACHE_TIMESTAMP="${state_timestamp}"

    return 0
}

# ---------------------------------------------------------------------------
# Grava o boot-state.json após um boot bem-sucedido
# ---------------------------------------------------------------------------
_boot_state_save() {
    local identity="$1"
    local worktree_path="$2"
    local branch="$3"
    local layers="$4"
    local artifact_paths="$5"

    if [[ -z "${identity}" || -z "${worktree_path}" ]]; then
        return 1
    fi

    _ensure_boot_cache_dir "${worktree_path}" || return 1

    local state_file tmp_file
    state_file="$(_boot_state_file_path "${worktree_path}")"
    tmp_file="${state_file}.tmp.$$"

    local timestamp
    timestamp="$(date +%s 2>/dev/null || echo 0)"

    # Constrói JSON de digests
    local digests_json="{}"
    local artifact_path
    for artifact_path in ${artifact_paths}; do
        [[ -z "${artifact_path}" ]] && continue
        local digest
        digest="$(_boot_state_compute_digest "${artifact_path}")"
        if [[ -n "${digest}" ]]; then
            digests_json="$(printf '%s' "${digests_json}" | ${AG_PYTHON:-python3} -c "import sys,json; d=json.load(sys.stdin); d[sys.argv[1]]=sys.argv[2]; print(json.dumps(d))" "${artifact_path}" "${digest}" 2>/dev/null || echo "{}")"
        fi
    done

    # Constrói array de layers
    local layers_json
    layers_json="$(printf '%s' "${layers}" | tr ' ' '\n' | ${AG_PYTHON:-python3} -c 'import sys,json; lines=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(lines))' 2>/dev/null || echo '[]')"

    ${AG_PYTHON:-python3} -c "
import sys, json
out = {
    'identity': sys.argv[1],
    'branch': sys.argv[2],
    'worktree': sys.argv[3],
    'boot_timestamp': int(sys.argv[4]),
    'ttl_seconds': int(sys.argv[5]),
    'layers': json.loads(sys.argv[6]),
    'artifact_digests': json.loads(sys.argv[7])
}
print(json.dumps(out, indent=2, ensure_ascii=False))
" "${identity}" "${branch}" "${worktree_path}" "${timestamp}" "${HMVIP_BOOT_CACHE_TTL_SECONDS}" "${layers_json}" "${digests_json}" > "${tmp_file}" 2>/dev/null || {
        rm -f "${tmp_file}"
        return 1
    }

    mv "${tmp_file}" "${state_file}" 2>/dev/null || {
        rm -f "${tmp_file}"
        return 1
    }

    return 0
}

# ---------------------------------------------------------------------------
# Invalida o boot cache (útil em mudanças críticas ou release)
# ---------------------------------------------------------------------------
_boot_state_invalidate() {
    local worktree_path="$1"
    if [[ -z "${worktree_path}" ]]; then
        return 0
    fi
    local state_file
    state_file="$(_boot_state_file_path "${worktree_path}")"
    rm -f "${state_file}"
}
