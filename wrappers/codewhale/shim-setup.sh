#!/usr/bin/env bash
#
# Agent Guard — CodeWhale Shim Installer
#
# Installs the auto-recovery shim so that `codewhale` in PATH always resolves
# to the Agent Guard wrapper, even after `npm install -g codewhale`.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=""
SHIM_DIR=""
SKIP_CONFIRM="false"

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
        --shim-dir)
            SHIM_DIR="${2:-}"
            shift 2
            ;;
        --shim-dir=*)
            SHIM_DIR="${1#*=}"
            shift
            ;;
        --yes)
            SKIP_CONFIRM="true"
            shift
            ;;
        -h|--help)
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *)
            echo "❌ Unknown argument: $1" >&2
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
        REPO_ROOT="/home/hmvip-dev/hmvip"
    fi
fi
REPO_ROOT="$(cd "${REPO_ROOT}" && pwd)"

if [[ ! -f "${REPO_ROOT}/agent-guard.yaml" ]]; then
    echo "❌ Repository root does not contain agent-guard.yaml: ${REPO_ROOT}" >&2
    exit 1
fi

AGENT_GUARD_CONFIG="${REPO_ROOT}/packages/agent-guard-core/bin/agent-guard-config"
CODEWHALE_BIN_DIR="${HOME}/.npm-global/bin"
if [[ -f "${AGENT_GUARD_CONFIG}" ]]; then
    CODEWHALE_BIN_DIR="$(bash "${AGENT_GUARD_CONFIG}" get wrappers.codewhale.bin_dir "${CODEWHALE_BIN_DIR}" 2>/dev/null || echo "${CODEWHALE_BIN_DIR}")"
fi

if [[ -z "${SHIM_DIR}" ]]; then
    # Default to the same directory used by the Amp wrapper because it is
    # already first in PATH for HMVIP shells.
    SHIM_DIR="${HOME}/.local/hmvip/bin"
fi
mkdir -p "${SHIM_DIR}"

SHIM_TARGET="${SHIM_DIR}/codewhale"
SHIM_SRC="${SCRIPT_DIR}/shim.sh"

if [[ ! -f "${SHIM_SRC}" ]]; then
    echo "❌ Shim source not found: ${SHIM_SRC}" >&2
    exit 1
fi

echo "🛡️  CodeWhale auto-recovery shim"
echo "   Source: ${SHIM_SRC}"
echo "   Target: ${SHIM_TARGET}"
echo "   Wrapper bin dir: ${CODEWHALE_BIN_DIR}"

if [[ -f "${SHIM_TARGET}" ]]; then
    echo "⚠️  A file already exists at ${SHIM_TARGET}."
    if [[ "${SKIP_CONFIRM}" != "true" ]]; then
        read -rp "   Overwrite with the Agent Guard shim? [y/N] " reply
        if [[ "${reply}" != "y" && "${reply}" != "Y" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
fi

cp "${SHIM_SRC}" "${SHIM_TARGET}"
chmod +x "${SHIM_TARGET}"

# Warn if the shim directory is not before the npm global bin dir in PATH.
# If it is not, the npm launcher will still win and the shim does nothing.
_before_npm="false"
IFS=':' read -ra _path_dirs <<< "${PATH}"
for d in "${_path_dirs[@]}"; do
    if [[ "$(cd "${d}" 2>/dev/null && pwd)" == "$(cd "${SHIM_DIR}" 2>/dev/null && pwd)" ]]; then
        _before_npm="true"
        break
    fi
    if [[ "$(cd "${d}" 2>/dev/null && pwd)" == "$(cd "${CODEWHALE_BIN_DIR}" 2>/dev/null && pwd)" ]]; then
        break
    fi
done

if [[ "${_before_npm}" != "true" ]]; then
    echo ""
    echo "⚠️  ${SHIM_DIR} is NOT before ${CODEWHALE_BIN_DIR} in PATH." >&2
    echo "   The shim will not intercept codewhale until you fix PATH order." >&2
    echo "   Add this to your ~/.bashrc (or equivalent) before any npm PATH:" >&2
    echo "     export PATH=\"${SHIM_DIR}:\$PATH\"" >&2
else
    echo "✅ Shim directory is before the npm global bin dir in PATH."
fi

# Warn about stale real binary that may bypass the shim in some PATH orders.
if [[ -f "${HOME}/.local/bin/codewhale" ]]; then
    local_bin_type="$(file "${HOME}/.local/bin/codewhale" 2>/dev/null || true)"
    if echo "${local_bin_type}" | grep -q "ELF"; then
        echo ""
        echo "⚠️  Found a stale ELF binary at ${HOME}/.local/bin/codewhale." >&2
        echo "   It is NOT the Agent Guard wrapper. If your PATH ever resolves" >&2
        echo "   to it before the shim, isolation will be bypassed." >&2
        echo "   Consider removing it after confirming it is unused." >&2
    fi
fi

# Create per-slot symlinks so users can type `codewhale1`, `codewhale2`, etc.
_SLOTS="$(bash "${AGENT_GUARD_CONFIG}" get identities.codewhale.slots '2' 2>/dev/null || echo '2')"
for _n in $(seq 1 "${_SLOTS}"); do
    _slot_link="${SHIM_DIR}/codewhale${_n}"
    rm -f "${_slot_link}"
    ln -s "${SHIM_TARGET}" "${_slot_link}"
done

echo ""
echo "✅ Created slot symlinks: codewhale1 .. codewhale${_SLOTS} in ${SHIM_DIR}"
echo ""
echo "✅ CodeWhale shim installed."
echo "   Next time npm replaces the wrapper, the shim will restore it automatically."
echo "   To remove it later, delete ${SHIM_TARGET}"
