#!/usr/bin/env bash
#
# Agent Guard — Kimi CLI Wrapper Recovery
#
# Restores the Agent Guard isolation wrapper after Kimi CLI self-updates or any
# other event that replaces <bin_dir>/kimi with the real binary.
#
# Usage:
#   bash /path/to/recovery.sh [--repo-root /path/to/repo] [--remove-wrapper]
#
# The script:
#   1. Checks whether <bin_dir>/kimi is still the wrapper.
#   2. If not, backs up the current binary as kimi.real.<timestamp>.
#   3. Copies the versioned wrapper to <bin_dir>/kimi.
#   4. Ensures <bin_dir>/kimi.real points to the real binary.
#
# With --remove-wrapper:
#   1. Backs up the current wrapper as kimi.wrapper.<timestamp>.
#   2. Restores the real binary from kimi.real back to kimi.
#   3. Leaves kimi.real in place for reference.
#
set -euo pipefail

# Parse optional arguments.
REPO_ROOT=""
REMOVE_WRAPPER="false"
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
        --remove-wrapper)
            REMOVE_WRAPPER="true"
            shift
            ;;
        *)
            echo "❌ Unknown argument: $1" >&2
            echo "   Usage: $0 [--repo-root /path/to/repo] [--remove-wrapper]" >&2
            exit 1
            ;;
    esac
done

# Detect repository root (explicit --repo-root, current worktree, or env var).
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

# Load Agent Guard configuration from agent-guard.yaml.
PACKAGE_ROOT="packages/agent-guard-core"
KIMI_BIN_DIR="${AG_KIMI_BIN_DIR:-${AG_KIMI_BIN_DIR:-${HOME}/.kimi-code/bin}}"

AGENT_GUARD_CONFIG="${REPO_ROOT}/${PACKAGE_ROOT}/bin/agent-guard-config"
if [[ -f "${AGENT_GUARD_CONFIG}" ]]; then
    PACKAGE_ROOT="$(bash "${AGENT_GUARD_CONFIG}" get paths.package_root 'packages/agent-guard-core' 2>/dev/null || echo 'packages/agent-guard-core')"
    KIMI_BIN_DIR="$(bash "${AGENT_GUARD_CONFIG}" get wrappers.kimi.bin_dir "${KIMI_BIN_DIR}" 2>/dev/null || echo "${KIMI_BIN_DIR}")"
fi

WRAPPER_SRC="${REPO_ROOT}/${PACKAGE_ROOT}/wrappers/kimi/wrapper.sh"
KIMI_BIN="${KIMI_BIN_DIR}/kimi"
KIMI_REAL="${KIMI_BIN_DIR}/kimi.real"

_is_wrapper() {
    local path="$1"
    [[ -f "${path}" ]] && head -n 5 "${path}" 2>/dev/null | grep -q "Agent Guard — Kimi CLI Wrapper"
}

_is_elf() {
    local path="$1"
    [[ -f "${path}" ]] && file "${path}" 2>/dev/null | grep -q "ELF"
}

if [[ ! -f "${WRAPPER_SRC}" ]]; then
    echo "❌ Wrapper source not found: ${WRAPPER_SRC}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Remove invasive wrapper and restore real binary (non-invasive uninstall).
# ---------------------------------------------------------------------------
if [[ "${REMOVE_WRAPPER}" == "true" ]]; then
    if ! _is_wrapper "${KIMI_BIN}"; then
        echo "✅ ${KIMI_BIN} is not the Agent Guard wrapper. No removal needed."
        exit 0
    fi

    echo "⚠️  Removing invasive Agent Guard wrapper from ${KIMI_BIN}..."

    timestamp="$(date +%Y%m%d-%H%M%S)"
    wrapper_backup="${KIMI_BIN_DIR}/kimi.wrapper.${timestamp}"
    cp "${KIMI_BIN}" "${wrapper_backup}"
    echo "💾 Backed up wrapper to ${wrapper_backup}"

    if [[ ! -f "${KIMI_REAL}" ]]; then
        echo "❌ Real Kimi binary not found at ${KIMI_REAL}." >&2
        echo "   Cannot restore the original binary. Aborting removal." >&2
        exit 1
    fi

    cp "${KIMI_REAL}" "${KIMI_BIN}"
    chmod +x "${KIMI_BIN}"

    if ! _is_wrapper "${KIMI_BIN}"; then
        echo "✅ Invasive wrapper removed; ${KIMI_BIN} restored to real binary."
        echo "   Wrapper backup: ${wrapper_backup}"
        exit 0
    else
        echo "❌ Failed to remove wrapper at ${KIMI_BIN}" >&2
        exit 1
    fi
fi

# Nothing to do if already wrapper.
if _is_wrapper "${KIMI_BIN}"; then
    echo "✅ ${KIMI_BIN} is already the Agent Guard wrapper."
    exit 0
fi

echo "⚠️  ${KIMI_BIN} is not the Agent Guard wrapper. Starting recovery..."

mkdir -p "${KIMI_BIN_DIR}"

# If current binary exists and is ELF, preserve it as the real binary.
if [[ -f "${KIMI_BIN}" ]]; then
    if _is_elf "${KIMI_BIN}"; then
        timestamp="$(date +%Y%m%d-%H%M%S)"
        backup_bin="${KIMI_BIN_DIR}/kimi.real.${timestamp}"
        cp "${KIMI_BIN}" "${backup_bin}"
        echo "💾 Backed up current binary to ${backup_bin}"

        if [[ ! -f "${KIMI_REAL}" ]] || [[ "${KIMI_BIN}" -nt "${KIMI_REAL}" ]]; then
            cp "${KIMI_BIN}" "${KIMI_REAL}"
            echo "🔄 Updated ${KIMI_REAL} to current binary."
        fi
    else
        echo "⚠️  ${KIMI_BIN} exists but is neither wrapper nor ELF; moving aside."
        mv "${KIMI_BIN}" "${KIMI_BIN}.unknown.$(date +%Y%m%d-%H%M%S)"
    fi
fi

# If no kimi.real, try to restore from the newest ELF backup.
if [[ ! -f "${KIMI_REAL}" ]]; then
    newest_real="$(find "${KIMI_BIN_DIR}" -maxdepth 1 -type f -name 'kimi.real*' -print0 2>/dev/null | \
        xargs -0 -r ls -t 2>/dev/null | head -n 1)"
    if [[ -n "${newest_real}" ]] && _is_elf "${newest_real}"; then
        cp "${newest_real}" "${KIMI_REAL}"
        echo "🔄 Restored ${KIMI_REAL} from ${newest_real}"
    fi
fi

if [[ ! -f "${KIMI_REAL}" ]]; then
    echo "❌ Could not locate a real kimi binary to use as ${KIMI_REAL}." >&2
    echo "   Please reinstall Kimi CLI or restore ${KIMI_REAL} manually." >&2
    exit 1
fi

chmod +x "${KIMI_REAL}"

# Install the wrapper.
cp "${WRAPPER_SRC}" "${KIMI_BIN}"
chmod +x "${KIMI_BIN}"

if _is_wrapper "${KIMI_BIN}"; then
    echo "✅ Wrapper restored successfully."
    echo "   Wrapper: ${KIMI_BIN}"
    echo "   Real binary: ${KIMI_REAL}"
    exit 0
else
    echo "❌ Failed to install wrapper at ${KIMI_BIN}" >&2
    exit 1
fi
