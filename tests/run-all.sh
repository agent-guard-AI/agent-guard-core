#!/usr/bin/env bash
#
# Run all agent-guard-core tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🧪 Running agent-guard-core test suite..."
echo ""

bash "${SCRIPT_DIR}/shell-syntax-test.sh"
bash "${SCRIPT_DIR}/agent-guard-cli-test.sh"
bash "${SCRIPT_DIR}/install-test.sh"

echo ""
echo "✅ All agent-guard-core tests passed."
