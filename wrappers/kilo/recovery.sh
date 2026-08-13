#!/usr/bin/env bash
#
# Agent Guard — Kilo CLI Wrapper Recovery
#
# Restores the Agent Guard isolation wrapper after Kilo CLI self-updates or any
# other event that replaces <bin_dir>/kilo with the real binary.
#
# Usage:
#   bash /path/to/recovery.sh [--repo-root /path/to/repo]
#
# The script:
#   1. Checks whether <bin_dir>/kilo is still the wrapper.
#   2. If not, backs up the current binary as kilo.real.<timestamp>.
#   3. Copies the versioned wrapper to <bin_dir>/kilo.
#   4. Ensures <bin_dir>/kilo.real points to the real binary.
#   5. Prunes old kilo.real.* backups, keeping only the newest few
#      (AG_KILO_BACKUP_KEEP, default 3) — without retention each backup
#      (~150 MB) accumulates forever and can fill the disk.
#
set -euo pipefail

# Parse optional --repo-root.
REPO_ROOT=""
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
        *)
            echo "❌ Unknown argument: $1" >&2
            echo "   Usage: $0 [--repo-root /path/to/repo]" >&2
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
KILO_BIN_DIR="${AG_KILO_BIN_DIR:-${AG_KILO_BIN_DIR:-${HOME}/.kilocode/bin}}"

AGENT_GUARD_CONFIG="${REPO_ROOT}/${PACKAGE_ROOT}/bin/agent-guard-config"
if [[ -f "${AGENT_GUARD_CONFIG}" ]]; then
    PACKAGE_ROOT="$(bash "${AGENT_GUARD_CONFIG}" get paths.package_root 'packages/agent-guard-core' 2>/dev/null || echo 'packages/agent-guard-core')"
    KILO_BIN_DIR="$(bash "${AGENT_GUARD_CONFIG}" get wrappers.kilo.bin_dir "${KILO_BIN_DIR}" 2>/dev/null || echo "${KILO_BIN_DIR}")"
fi

WRAPPER_SRC="${REPO_ROOT}/${PACKAGE_ROOT}/wrappers/kilo/wrapper.sh"
KILO_BIN="${KILO_BIN_DIR}/kilo"
KILO_REAL="${KILO_BIN_DIR}/kilo.real"

if [[ ! -f "${WRAPPER_SRC}" ]]; then
    echo "❌ Wrapper source not found: ${WRAPPER_SRC}" >&2
    exit 1
fi

_is_wrapper() {
    local path="$1"
    [[ -f "${path}" ]] && head -n 5 "${path}" 2>/dev/null | grep -q "Agent Guard — Kilo CLI Wrapper"
}

_is_elf() {
    local path="$1"
    [[ -f "${path}" ]] && file "${path}" 2>/dev/null | grep -q "ELF"
}

# Atomically replace a target file with the contents of a source file.
# Works even when the target is an ELF binary currently being executed,
# avoiding ETXTBSY ("text file busy").
_ag_atomic_replace() {
    local source="$1"
    local target="$2"
    local tmp_target="${target}.tmp.$$"
    cp "${source}" "${tmp_target}"
    chmod +x "${tmp_target}"
    mv "${tmp_target}" "${target}"
}

# Prune timestamped kilo.real.* backups, keeping only the newest few.
# Every recovery run creates one backup (~150 MB); without retention they
# accumulate indefinitely and can fill the disk. The canonical kilo.real
# (no suffix) is never matched by the 'kilo.real.*' glob.
_ag_prune_real_backups() {
    local keep="${AG_KILO_BACKUP_KEEP:-3}"
    [[ "${keep}" =~ ^[0-9]+$ ]] || keep=3
    local old_backups
    old_backups="$(find "${KILO_BIN_DIR}" -maxdepth 1 -type f -name 'kilo.real.*' -print0 2>/dev/null | \
        xargs -0 -r ls -t 2>/dev/null | tail -n "+$((keep + 1))" || true)"
    [[ -z "${old_backups}" ]] && return 0
    local count=0
    local old_backup
    while IFS= read -r old_backup; do
        [[ -z "${old_backup}" ]] && continue
        rm -f -- "${old_backup}" && count=$((count + 1))
    done <<< "${old_backups}"
    if [[ "${count}" -gt 0 ]]; then
        echo "🧹 Pruned ${count} old kilo.real backup(s); kept the newest ${keep}."
    fi
}

# Retention runs on every invocation, including no-op "already wrapper" runs,
# so a backup burst is cleaned up even when no recovery is needed.
_ag_prune_real_backups

# Nothing to do if already wrapper.
if _is_wrapper "${KILO_BIN}"; then
    echo "✅ ${KILO_BIN} is already the Agent Guard wrapper."
    exit 0
fi

echo "⚠️  ${KILO_BIN} is not the Agent Guard wrapper. Starting recovery..."

mkdir -p "${KILO_BIN_DIR}"

# If current binary exists and is ELF, preserve it as the real binary.
if [[ -f "${KILO_BIN}" ]]; then
    if _is_elf "${KILO_BIN}"; then
        timestamp="$(date +%Y%m%d-%H%M%S)"
        backup_bin="${KILO_BIN_DIR}/kilo.real.${timestamp}"
        cp "${KILO_BIN}" "${backup_bin}"
        echo "💾 Backed up current binary to ${backup_bin}"
        # Re-prune so the fresh backup counts toward the retention window.
        _ag_prune_real_backups

        if [[ ! -f "${KILO_REAL}" ]] || [[ "${KILO_BIN}" -nt "${KILO_REAL}" ]]; then
            _ag_atomic_replace "${KILO_BIN}" "${KILO_REAL}"
            echo "🔄 Updated ${KILO_REAL} to current binary."
        fi
    else
        echo "⚠️  ${KILO_BIN} exists but is neither wrapper nor ELF; moving aside."
        mv "${KILO_BIN}" "${KILO_BIN}.unknown.$(date +%Y%m%d-%H%M%S)"
    fi
fi

# If no kilo.real, try to restore from the newest ELF backup.
if [[ ! -f "${KILO_REAL}" ]]; then
    newest_real="$(find "${KILO_BIN_DIR}" -maxdepth 1 -type f -name 'kilo.real*' -print0 2>/dev/null | \
        xargs -0 -r ls -t 2>/dev/null | head -n 1)"
    if [[ -n "${newest_real}" ]] && _is_elf "${newest_real}"; then
        _ag_atomic_replace "${newest_real}" "${KILO_REAL}"
        echo "🔄 Restored ${KILO_REAL} from ${newest_real}"
    fi
fi

if [[ ! -f "${KILO_REAL}" ]]; then
    echo "❌ Could not locate a real kilo binary to use as ${KILO_REAL}." >&2
    echo "   Please reinstall Kilo CLI or restore ${KILO_REAL} manually." >&2
    exit 1
fi

chmod +x "${KILO_REAL}"

# Install the wrapper atomically so we never write over an executing ELF.
_ag_atomic_replace "${WRAPPER_SRC}" "${KILO_BIN}"

if _is_wrapper "${KILO_BIN}"; then
    echo "✅ Wrapper restored successfully."
    echo "   Wrapper: ${KILO_BIN}"
    echo "   Real binary: ${KILO_REAL}"
    exit 0
else
    echo "❌ Failed to install wrapper at ${KILO_BIN}" >&2
    exit 1
fi
