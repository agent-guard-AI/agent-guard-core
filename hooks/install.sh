#!/usr/bin/env bash
#
# hooks/install.sh — Installs agent-guard-core Git hooks into the consumer repo.
#
# Usage:
#   ./packages/agent-guard-core/hooks/install.sh [--target <repo-root>]
#
# The script:
#   1. Detects the repository root via git or the --target option.
#   2. Creates the .githooks/ directory at the root (if needed).
#   3. Copies hooks from the package to .githooks/.
#   4. Configures core.hooksPath to point to .githooks/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            REPO_ROOT="${2:-}"
            shift 2
            ;;
        --target=*)
            REPO_ROOT="${1#*=}"
            shift
            ;;
        *)
            echo "❌ Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${REPO_ROOT}" ]]; then
    REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "")"
fi

if [[ -z "${REPO_ROOT}" ]]; then
    echo "❌ Not inside a git repository. Use --target <repo-root>." >&2
    exit 1
fi

REPO_ROOT="$(cd "${REPO_ROOT}" && pwd)"
HOOKS_SRC="${SCRIPT_DIR}"
HOOKS_DST="${REPO_ROOT}/.githooks"

mkdir -p "${HOOKS_DST}"

for hook in post-commit pre-push pre-commit pre-checkout commit-msg post-checkout; do
    src="${HOOKS_SRC}/${hook}"
    dst="${HOOKS_DST}/${hook}"
    if [[ ! -f "${src}" ]]; then
        echo "⚠️  Hook source not found: ${src}" >&2
        continue
    fi
    cp "${src}" "${dst}"
    chmod +x "${dst}"
    echo "   ✅ Installed ${hook}"
done

# Configure core.hooksPath locally (worktree-scoped) to use .githooks
git -C "${REPO_ROOT}" config --worktree core.hooksPath "${HOOKS_DST}"

echo ""
echo "🛡️  Agent Guard hooks installed at ${HOOKS_DST}"
echo "   core.hooksPath set to: ${HOOKS_DST}"
