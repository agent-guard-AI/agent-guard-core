#!/usr/bin/env bash
#
# Agent Guard — Amp CLI Wrapper Recovery
#
# Restores the Agent Guard wrapper at its stable location without modifying
# Amp's real binary.
#
# Usage:
#   bash /path/to/recovery.sh [--repo-root /path/to/repo]
#
set -euo pipefail

REPO_ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            if [[ -z "${2:-}" ]]; then
                echo "❌ --repo-root requires a path." >&2
                exit 1
            fi
            REPO_ROOT="$2"
            shift 2
            ;;
        --repo-root=*)
            REPO_ROOT="${1#*=}"
            shift
            ;;
        *)
            echo "❌ Unknown argument: $1" >&2
            echo "   Usage: $0 [--repo-root /path/to/repo]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${REPO_ROOT}" ]]; then
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
        REPO_ROOT="$(git rev-parse --show-toplevel)"
    elif [[ -n "${AG_REPO_ROOT:-}" ]]; then
        REPO_ROOT="${AG_REPO_ROOT}"
    else
        echo "❌ Could not detect repository root." >&2
        echo "   Run from inside a repository, pass --repo-root, or set AG_REPO_ROOT." >&2
        exit 1
    fi
fi

PACKAGE_ROOT="packages/agent-guard-core"
AMP_BIN_DIR="${HOME}/.local/hmvip/bin"
AMP_REAL_BIN="${HOME}/.amp/bin/amp"

AGENT_GUARD_CONFIG="${REPO_ROOT}/${PACKAGE_ROOT}/bin/agent-guard-config"
if [[ -f "${AGENT_GUARD_CONFIG}" ]]; then
    PACKAGE_ROOT="$(AGENT_GUARD_REPO_ROOT="${REPO_ROOT}" bash "${AGENT_GUARD_CONFIG}" get paths.package_root "${PACKAGE_ROOT}" 2>/dev/null || echo "${PACKAGE_ROOT}")"
    AGENT_GUARD_CONFIG="${REPO_ROOT}/${PACKAGE_ROOT}/bin/agent-guard-config"
    AMP_BIN_DIR="$(AGENT_GUARD_REPO_ROOT="${REPO_ROOT}" bash "${AGENT_GUARD_CONFIG}" get wrappers.amp.bin_dir "${AMP_BIN_DIR}" 2>/dev/null || echo "${AMP_BIN_DIR}")"
    AMP_REAL_BIN="$(AGENT_GUARD_REPO_ROOT="${REPO_ROOT}" bash "${AGENT_GUARD_CONFIG}" get wrappers.amp.real_bin_path "${AMP_REAL_BIN}" 2>/dev/null || echo "${AMP_REAL_BIN}")"
fi

WRAPPER_SRC="${REPO_ROOT}/${PACKAGE_ROOT}/wrappers/amp/wrapper.sh"
AMP_WRAPPER="${AMP_BIN_DIR}/amp"

if [[ ! -f "${WRAPPER_SRC}" ]]; then
    echo "❌ Wrapper source not found: ${WRAPPER_SRC}" >&2
    exit 1
fi

_is_wrapper() {
    local path="$1"
    [[ -f "${path}" ]] && head -n 10 "${path}" 2>/dev/null | grep -q "Agent Guard — Amp CLI Wrapper"
}

mkdir -p "${AMP_BIN_DIR}"

if _is_wrapper "${AMP_WRAPPER}"; then
    echo "✅ ${AMP_WRAPPER} is already the Agent Guard wrapper."
else
    cp "${WRAPPER_SRC}" "${AMP_WRAPPER}"
    echo "✅ Installed Agent Guard wrapper at ${AMP_WRAPPER}."
fi
chmod +x "${AMP_WRAPPER}"

if [[ ! -f "${AMP_REAL_BIN}" ]]; then
    echo "⚠️  Amp real binary not found: ${AMP_REAL_BIN}" >&2
    echo "   Install Amp before using the wrapper." >&2
fi

amp_path_index=-1
local_bin_index=-1
path_index=0
IFS=':' read -r -a path_entries <<< "${PATH:-}"
for path_entry in "${path_entries[@]}"; do
    [[ "${path_entry}" == "${AMP_BIN_DIR}" ]] && amp_path_index=${path_index}
    [[ "${path_entry}" == "${HOME}/.local/bin" ]] && local_bin_index=${path_index}
    path_index=$((path_index + 1))
done

if [[ ${amp_path_index} -lt 0 ]]; then
    echo "⚠️  ${AMP_BIN_DIR} is not in PATH." >&2
elif [[ ${local_bin_index} -ge 0 && ${amp_path_index} -gt ${local_bin_index} ]]; then
    echo "⚠️  ${AMP_BIN_DIR} comes after ${HOME}/.local/bin in PATH." >&2
    echo "   Put ${AMP_BIN_DIR} first so the Agent Guard wrapper takes precedence." >&2
fi

exit 0
