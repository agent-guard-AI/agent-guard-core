#!/usr/bin/env bash
#
# Validate syntax of all shell scripts in the package.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERRORS=0

fail() {
    echo "❌ FAIL: $1" >&2
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "✅ PASS: $1"
}

while IFS= read -r -d '' file; do
    if ! bash -n "${file}"; then
        fail "syntax error in ${file}"
    fi
done < <(find "${REPO_ROOT}" -type f -name '*.sh' -print0)

pass "all shell scripts have valid syntax"

echo ""
if [[ ${ERRORS} -gt 0 ]]; then
    echo "❌ ${ERRORS} test(s) failed."
    exit 1
fi

echo "✅ Shell syntax tests passed."
