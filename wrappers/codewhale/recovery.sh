#!/usr/bin/env bash
#
# Agent Guard — CodeWhale CLI Wrapper Recovery
#
# Restores the Agent Guard isolation wrapper after CodeWhale CLI self-updates or
# any other event that replaces <bin_dir>/codewhale with the real npm launcher.
#
# Usage:
#   bash /path/to/recovery.sh [--repo-root /path/to/repo]
#
# The script:
#   1. Checks whether <bin_dir>/codewhale is still the wrapper.
#   2. If not, backs up the current launcher as codewhale.real.<timestamp>.
#   3. Ensures <bin_dir>/codewhale.real points to the real npm launcher script.
#   4. Copies the versioned wrapper to <bin_dir>/codewhale.
#   5. Prunes old codewhale.real.* backups, keeping only the newest few
#      (AG_CODEWHALE_BACKUP_KEEP, default 3) — without retention each backup
#      accumulates forever and can fill the disk.
#
# Unlike the Kimi/Kilo recovery, CodeWhale's entrypoint is a Node.js script
# (bin/codewhale.js) that resolves the native binary relative to its own
# directory. We therefore keep the real launcher as a script/symlink, not an
# ELF, and the wrapper always falls back to the canonical npm script path if
# the backup launcher is stale.
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
CODEWHALE_BIN_DIR="${AG_CODEWHALE_BIN_DIR:-${AG_CODEWHALE_BIN_DIR:-${HOME}/.npm-global/bin}}"

export AGENT_GUARD_REPO_ROOT="${REPO_ROOT}"
AGENT_GUARD_CONFIG="${REPO_ROOT}/${PACKAGE_ROOT}/bin/agent-guard-config"
if [[ -f "${AGENT_GUARD_CONFIG}" ]]; then
    PACKAGE_ROOT="$(bash "${AGENT_GUARD_CONFIG}" get paths.package_root 'packages/agent-guard-core' 2>/dev/null || echo 'packages/agent-guard-core')"
    CODEWHALE_BIN_DIR="$(bash "${AGENT_GUARD_CONFIG}" get wrappers.codewhale.bin_dir "${CODEWHALE_BIN_DIR}" 2>/dev/null || echo "${CODEWHALE_BIN_DIR}")"
fi

WRAPPER_SRC="${REPO_ROOT}/${PACKAGE_ROOT}/wrappers/codewhale/wrapper.sh"
CODEWHALE_BIN="${CODEWHALE_BIN_DIR}/codewhale"
CODEWHALE_REAL="${CODEWHALE_BIN_DIR}/codewhale.real"

# Canonical npm launcher script. The wrapper falls back to this path when the
# backup launcher is missing or stale, so updates to the npm package are picked
# up automatically.
NPM_SCRIPT_CANONICAL="$(cd "${CODEWHALE_BIN_DIR}" 2>/dev/null && realpath -m "../lib/node_modules/codewhale/bin/codewhale.js" 2>/dev/null || echo "${CODEWHALE_BIN_DIR}/../lib/node_modules/codewhale/bin/codewhale.js")"

if [[ ! -f "${WRAPPER_SRC}" ]]; then
    echo "❌ Wrapper source not found: ${WRAPPER_SRC}" >&2
    exit 1
fi

_is_wrapper() {
    local path="$1"
    [[ -f "${path}" ]] && head -n 5 "${path}" 2>/dev/null | grep -q "Agent Guard — CodeWhale CLI Wrapper"
}

# Resolve the real npm launcher script, following symlinks if present.
_resolve_real_script() {
    local path="$1"
    if [[ -L "${path}" ]]; then
        local target
        target="$(readlink "${path}" 2>/dev/null || true)"
        if [[ "${target}" == /* ]]; then
            echo "${target}"
        else
            echo "$(cd "$(dirname "${path}")" 2>/dev/null && pwd)/${target}"
        fi
        return 0
    fi
    if [[ -f "${path}" ]]; then
        echo "${path}"
        return 0
    fi
    return 1
}

# Atomically replace a target file with the contents of a source file.
_ag_atomic_replace() {
    local source="$1"
    local target="$2"
    local tmp_target="${target}.tmp.$$"
    cp "${source}" "${tmp_target}"
    chmod +x "${tmp_target}"
    mv "${tmp_target}" "${target}"
}

# Prune timestamped codewhale.real.* backups, keeping only the newest few.
_ag_prune_real_backups() {
    local keep="${AG_CODEWHALE_BACKUP_KEEP:-3}"
    [[ "${keep}" =~ ^[0-9]+$ ]] || keep=3
    local old_backups
    old_backups="$(find "${CODEWHALE_BIN_DIR}" -maxdepth 1 -type f -name 'codewhale.real.*' -print0 2>/dev/null | \
        xargs -0 -r ls -t 2>/dev/null | tail -n "+$((keep + 1))" || true)"
    [[ -z "${old_backups}" ]] && return 0
    local count=0
    local old_backup
    while IFS= read -r old_backup; do
        [[ -z "${old_backup}" ]] && continue
        rm -f -- "${old_backup}" && count=$((count + 1))
    done <<< "${old_backups}"
    if [[ "${count}" -gt 0 ]]; then
        echo "🧹 Pruned ${count} old codewhale.real backup(s); kept the newest ${keep}."
    fi
}

# Retention runs on every invocation, including no-op "already wrapper" runs,
# so a backup burst is cleaned up even when no recovery is needed.
_ag_prune_real_backups

# Nothing to do if already wrapper AND matches the source.
if _is_wrapper "${CODEWHALE_BIN}" && cmp -s "${WRAPPER_SRC}" "${CODEWHALE_BIN}" 2>/dev/null; then
    echo "✅ ${CODEWHALE_BIN} is already the Agent Guard wrapper."
    exit 0
fi

echo "⚠️  ${CODEWHALE_BIN} is not the Agent Guard wrapper. Starting recovery..."

mkdir -p "${CODEWHALE_BIN_DIR}"

# Resolve what the current launcher points to (usually a symlink to the npm
# script, or the npm script itself if npm flattened the bin directory).
real_script=""
if [[ -e "${CODEWHALE_BIN}" ]]; then
    if real_script="$(_resolve_real_script "${CODEWHALE_BIN}")"; then
        timestamp="$(date +%Y%m%d-%H%M%S)"
        backup_bin="${CODEWHALE_BIN_DIR}/codewhale.real.${timestamp}"
        cp -a "${CODEWHALE_BIN}" "${backup_bin}" 2>/dev/null || cp "${CODEWHALE_BIN}" "${backup_bin}"
        echo "💾 Backed up current launcher to ${backup_bin}"
        # Re-prune so the fresh backup counts toward the retention window.
        _ag_prune_real_backups

        # If we found a real script behind the launcher, keep it as the
        # canonical bypass target. Prefer the canonical npm path if it exists
        # and is newer than the resolved target.
        if [[ -f "${NPM_SCRIPT_CANONICAL}" ]]; then
            if [[ ! -f "${CODEWHALE_REAL}" || "${NPM_SCRIPT_CANONICAL}" -nt "${CODEWHALE_REAL}" ]]; then
                ln -sf "${NPM_SCRIPT_CANONICAL}" "${CODEWHALE_REAL}.tmp.$$"
                mv "${CODEWHALE_REAL}.tmp.$$" "${CODEWHALE_REAL}"
                echo "🔄 Updated ${CODEWHALE_REAL} to canonical npm script."
            fi
        elif [[ -f "${real_script}" && ( ! -f "${CODEWHALE_REAL}" || "${real_script}" -nt "${CODEWHALE_REAL}" ) ]]; then
            ln -sf "${real_script}" "${CODEWHALE_REAL}.tmp.$$"
            mv "${CODEWHALE_REAL}.tmp.$$" "${CODEWHALE_REAL}"
            echo "🔄 Updated ${CODEWHALE_REAL} to resolved script: ${real_script}"
        fi
    else
        echo "⚠️  ${CODEWHALE_BIN} exists but could not be resolved to a real script; moving aside." >&2
        mv "${CODEWHALE_BIN}" "${CODEWHALE_BIN}.unknown.$(date +%Y%m%d-%H%M%S)"
    fi
fi

# If no codewhale.real, try to restore from the newest backup or canonical path.
if [[ ! -f "${CODEWHALE_REAL}" ]]; then
    if [[ -f "${NPM_SCRIPT_CANONICAL}" ]]; then
        ln -sf "${NPM_SCRIPT_CANONICAL}" "${CODEWHALE_REAL}.tmp.$$"
        mv "${CODEWHALE_REAL}.tmp.$$" "${CODEWHALE_REAL}"
        echo "🔄 Restored ${CODEWHALE_REAL} from canonical npm script."
    else
        newest_real="$(find "${CODEWHALE_BIN_DIR}" -maxdepth 1 -type f -name 'codewhale.real*' -print0 2>/dev/null | \
            xargs -0 -r ls -t 2>/dev/null | head -n 1)"
        if [[ -n "${newest_real}" && -f "${newest_real}" ]]; then
            ln -sf "${newest_real}" "${CODEWHALE_REAL}.tmp.$$"
            mv "${CODEWHALE_REAL}.tmp.$$" "${CODEWHALE_REAL}"
            echo "🔄 Restored ${CODEWHALE_REAL} from ${newest_real}"
        fi
    fi
fi

if [[ ! -f "${CODEWHALE_REAL}" ]]; then
    echo "❌ Could not locate a real codewhale script to use as ${CODEWHALE_REAL}." >&2
    echo "   Please reinstall CodeWhale CLI or restore ${CODEWHALE_REAL} manually." >&2
    exit 1
fi

# Install the wrapper atomically so we never write over an executing launcher.
_ag_atomic_replace "${WRAPPER_SRC}" "${CODEWHALE_BIN}"

if _is_wrapper "${CODEWHALE_BIN}"; then
    echo "✅ Wrapper restored successfully."
    echo "   Wrapper: ${CODEWHALE_BIN}"
    echo "   Real script: ${CODEWHALE_REAL}"
    exit 0
else
    echo "❌ Failed to install wrapper at ${CODEWHALE_BIN}" >&2
    exit 1
fi
