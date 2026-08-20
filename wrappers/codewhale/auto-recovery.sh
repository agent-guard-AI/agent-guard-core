#!/usr/bin/env bash
#
# Agent Guard — CodeWhale Wrapper Auto-Recovery
#
# Lightweight idempotent check meant to run before every `codewhale` invocation.
# If the npm global launcher was replaced by a CodeWhale self-update (or by
# `npm install -g codewhale`), restore the Agent Guard wrapper via recovery.sh.
#
set -euo pipefail

REPO_ROOT=""
QUIET="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            REPO_ROOT="${2:-}"
            shift 2
            ;;
        --repo-root=*)
            REPO_ROOT="${1#*=}"
            shift
            ;;
        --quiet|-q)
            QUIET="true"
            shift
            ;;
        *)
            echo "❌ Unknown argument: $1" >&2
            echo "   Usage: $0 [--repo-root /path/to/repo] [--quiet]" >&2
            exit 1
            ;;
    esac
done

# Resolve repository root. Prefer the current repo if it carries agent-guard.yaml,
# otherwise fall back to the canonical HMVIP root or the AG_REPO_ROOT override.
if [[ -z "${REPO_ROOT}" ]]; then
    if [[ -n "${AG_REPO_ROOT:-}" ]]; then
        REPO_ROOT="${AG_REPO_ROOT}"
    elif git rev-parse --show-toplevel >/dev/null 2>&1; then
        current_root="$(git rev-parse --show-toplevel)"
        if [[ -f "${current_root}/agent-guard.yaml" ]]; then
            REPO_ROOT="${current_root}"
        else
            REPO_ROOT="/home/hmvip-dev/hmvip"
        fi
    else
        REPO_ROOT="/home/hmvip-dev/hmvip"
    fi
fi

export AGENT_GUARD_REPO_ROOT="${REPO_ROOT}"

PACKAGE_ROOT="packages/agent-guard-core"
AGENT_GUARD_CONFIG="${REPO_ROOT}/${PACKAGE_ROOT}/bin/agent-guard-config"
if [[ -f "${AGENT_GUARD_CONFIG}" ]]; then
    PACKAGE_ROOT="$(bash "${AGENT_GUARD_CONFIG}" get paths.package_root 'packages/agent-guard-core' 2>/dev/null || echo 'packages/agent-guard-core')"
fi

RECOVERY_SCRIPT="${REPO_ROOT}/${PACKAGE_ROOT}/wrappers/codewhale/recovery.sh"
CODEWHALE_BIN_DIR="${HOME}/.npm-global/bin"
if [[ -f "${AGENT_GUARD_CONFIG}" ]]; then
    CODEWHALE_BIN_DIR="$(bash "${AGENT_GUARD_CONFIG}" get wrappers.codewhale.bin_dir "${CODEWHALE_BIN_DIR}" 2>/dev/null || echo "${CODEWHALE_BIN_DIR}")"
fi
CODEWHALE_BIN="${CODEWHALE_BIN_DIR}/codewhale"
WRAPPER_SRC="${REPO_ROOT}/${PACKAGE_ROOT}/wrappers/codewhale/wrapper.sh"

_is_wrapper() {
    local path="$1"
    [[ -f "${path}" ]] && head -n 5 "${path}" 2>/dev/null | grep -q "Agent Guard — CodeWhale CLI Wrapper"
}

# Nothing to do: wrapper is already in place AND matches the source.
if _is_wrapper "${CODEWHALE_BIN}" && cmp -s "${WRAPPER_SRC}" "${CODEWHALE_BIN}" 2>/dev/null; then
    exit 0
fi

if [[ "${QUIET}" != "true" ]]; then
    echo "⚠️  CodeWhale launcher at ${CODEWHALE_BIN} is not the Agent Guard wrapper." >&2
    echo "   Running auto-recovery..." >&2
fi

if [[ ! -f "${RECOVERY_SCRIPT}" ]]; then
    echo "❌ Recovery script not found: ${RECOVERY_SCRIPT}" >&2
    exit 1
fi

bash "${RECOVERY_SCRIPT}" --repo-root "${REPO_ROOT}"
