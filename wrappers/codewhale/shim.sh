#!/usr/bin/env bash
#
# Agent Guard — CodeWhale CLI Shim
#
# Sits in PATH before the npm global bin directory (e.g. ~/.local/hmvip/bin)
# and guarantees that the Agent Guard isolation wrapper is installed before
# delegating to it. npm global updates replace the wrapper with the real
# launcher; this shim transparently restores the wrapper on every call.
#
set -euo pipefail

# Emergency bypass: useful for debugging the real launcher without uninstalling
# the shim. Prefer AG_WRAPPER_BYPASS for the wrapper itself.
if [[ "${AG_SHIM_BYPASS:-}" == "1" ]]; then
    exec "${HOME}/.npm-global/bin/codewhale" "$@"
fi

# Resolve the repository root. Always use the canonical HMVIP root for the
# global shim so that stale worktrees never propagate an outdated wrapper.
# Override via AG_REPO_ROOT only for testing/emergency recovery.
REPO_ROOT="/home/hmvip-dev/hmvip"
if [[ -n "${AG_REPO_ROOT:-}" ]]; then
    REPO_ROOT="${AG_REPO_ROOT}"
fi

export AGENT_GUARD_REPO_ROOT="${REPO_ROOT}"
AUTO_RECOVERY="${REPO_ROOT}/packages/agent-guard-core/wrappers/codewhale/auto-recovery.sh"
if [[ -f "${AUTO_RECOVERY}" ]]; then
    bash "${AUTO_RECOVERY}" --repo-root "${REPO_ROOT}" --quiet
else
    echo "⚠️  CodeWhale shim could not locate auto-recovery script: ${AUTO_RECOVERY}" >&2
    echo "   Continuing without recovery. If the wrapper is missing, run:" >&2
    echo "     bash packages/agent-guard-core/wrappers/codewhale/recovery.sh --repo-root ${REPO_ROOT}" >&2
fi

# Load the configured CodeWhale bin directory from agent-guard.yaml.
PACKAGE_ROOT="packages/agent-guard-core"
AGENT_GUARD_CONFIG="${REPO_ROOT}/${PACKAGE_ROOT}/bin/agent-guard-config"
if [[ -f "${AGENT_GUARD_CONFIG}" ]]; then
    PACKAGE_ROOT="$(bash "${AGENT_GUARD_CONFIG}" get paths.package_root 'packages/agent-guard-core' 2>/dev/null || echo 'packages/agent-guard-core')"
fi

CODEWHALE_BIN_DIR="${HOME}/.npm-global/bin"
if [[ -f "${AGENT_GUARD_CONFIG}" ]]; then
    CODEWHALE_BIN_DIR="$(bash "${AGENT_GUARD_CONFIG}" get wrappers.codewhale.bin_dir "${CODEWHALE_BIN_DIR}" 2>/dev/null || echo "${CODEWHALE_BIN_DIR}")"
fi

# Delegate to the real wrapper (never to ourselves).
exec "${CODEWHALE_BIN_DIR}/codewhale" "$@"
