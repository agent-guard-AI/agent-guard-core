#!/usr/bin/env bash
#
# Agent Guard — CodeWhale Auto-Recovery Shim Test
#
# Validates that auto-recovery.sh detects a missing wrapper and restores it,
# and that a second invocation is a no-op.
#
set -euo pipefail

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

REPO_ROOT="${TMPDIR}/repo"
NPM_BIN_DIR="${TMPDIR}/npm-bin"

mkdir -p "${REPO_ROOT}/packages/agent-guard-core/bin"
mkdir -p "${REPO_ROOT}/packages/agent-guard-core/wrappers/codewhale"
mkdir -p "${NPM_BIN_DIR}"

# Copy real helpers from the repo under test.
cp "${BASH_SOURCE[0]%/*}/../bin/agent-guard-config" "${REPO_ROOT}/packages/agent-guard-core/bin/"
cp "${BASH_SOURCE[0]%/*}/../bin/agent-guard-python" "${REPO_ROOT}/packages/agent-guard-core/bin/"
cp "${BASH_SOURCE[0]%/*}/../wrappers/codewhale/wrapper.sh" "${REPO_ROOT}/packages/agent-guard-core/wrappers/codewhale/"
cp "${BASH_SOURCE[0]%/*}/../wrappers/codewhale/recovery.sh" "${REPO_ROOT}/packages/agent-guard-core/wrappers/codewhale/"
cp "${BASH_SOURCE[0]%/*}/../wrappers/codewhale/auto-recovery.sh" "${REPO_ROOT}/packages/agent-guard-core/wrappers/codewhale/"

# Minimal agent-guard.yaml pointing to the fake npm bin dir.
cat > "${REPO_ROOT}/agent-guard.yaml" <<EOF
paths:
  package_root: packages/agent-guard-core
wrappers:
  codewhale:
    bin_dir: ${NPM_BIN_DIR}
    real_bin: codewhale.real
    default_role: ia-a
EOF

# Simulate the real npm launcher.
cat > "${NPM_BIN_DIR}/codewhale.js" <<'EOF'
#!/usr/bin/env node
console.log("real npm launcher");
EOF
chmod +x "${NPM_BIN_DIR}/codewhale.js"

# Install the wrapper initially.
cp "${REPO_ROOT}/packages/agent-guard-core/wrappers/codewhale/wrapper.sh" "${NPM_BIN_DIR}/codewhale"
chmod +x "${NPM_BIN_DIR}/codewhale"

echo "1) Auto-recovery with wrapper in place should be silent..."
if ! bash "${REPO_ROOT}/packages/agent-guard-core/wrappers/codewhale/auto-recovery.sh" --repo-root "${REPO_ROOT}" --quiet; then
    echo "❌ FAIL: auto-recovery returned non-zero when wrapper was present" >&2
    exit 1
fi

echo "2) Simulate npm install -g codewhale..."
cp "${NPM_BIN_DIR}/codewhale.js" "${NPM_BIN_DIR}/codewhale"

if head -n 5 "${NPM_BIN_DIR}/codewhale" | grep -q "Agent Guard — CodeWhale CLI Wrapper"; then
    echo "❌ FAIL: simulated update did not replace the wrapper" >&2
    exit 1
fi

echo "3) Auto-recovery should restore the wrapper..."
if ! bash "${REPO_ROOT}/packages/agent-guard-core/wrappers/codewhale/auto-recovery.sh" --repo-root "${REPO_ROOT}" >/dev/null 2>&1; then
    echo "❌ FAIL: auto-recovery failed" >&2
    exit 1
fi

if ! head -n 5 "${NPM_BIN_DIR}/codewhale" | grep -q "Agent Guard — CodeWhale CLI Wrapper"; then
    echo "❌ FAIL: wrapper was not restored" >&2
    exit 1
fi

echo "4) Second auto-recovery should be a no-op..."
output="$(bash "${REPO_ROOT}/packages/agent-guard-core/wrappers/codewhale/auto-recovery.sh" --repo-root "${REPO_ROOT}" 2>&1)"
if [[ -n "${output}" ]]; then
    echo "❌ FAIL: auto-recovery was not silent on second run: ${output}" >&2
    exit 1
fi

echo "✅ All CodeWhale auto-recovery shim tests passed."
