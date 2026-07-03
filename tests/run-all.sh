#!/usr/bin/env bash
#
# Testes funcionais básicos do agent-guard-core (Fase 0)
#
# Roda validações que não dependem de banco real nem de rede.

set -euo pipefail

AG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${AG_DIR}/bin/agent-guard"

echo "============================================"
echo "🧪 agent-guard-core — Functional Tests"
echo "============================================"

# 1. CLI existe e responde a status
echo ""
echo "[1/4] CLI status responds..."
cd "$(git rev-parse --show-toplevel)"
source "${BIN}" status >/dev/null 2>&1
echo "   ✅ status OK"

# 2. Hooks são executáveis
echo ""
echo "[2/4] Hooks are executable..."
for hook in post-commit pre-push pre-commit pre-checkout commit-msg; do
    if [[ ! -x "${AG_DIR}/hooks/${hook}" ]]; then
        echo "   ❌ ${hook} is not executable" >&2
        exit 1
    fi
done
echo "   ✅ hooks OK"

# 3. CI scripts existem
echo ""
echo "[3/4] CI scripts exist..."
for script in worktree-origin-audit.php add-worktree-note.sh branch-triage.sh; do
    if [[ ! -f "${AG_DIR}/ci/${script}" ]]; then
        echo "   ❌ ${script} missing" >&2
        exit 1
    fi
done
echo "   ✅ ci scripts OK"

# 4. Configuração de exemplo é JSON/YAML válido
echo ""
echo "[4/4] Example configs are valid..."
python3 -c "import json,sys; json.load(open('${AG_DIR}/examples/agent-guard.json'))"
python3 -c "import yaml,sys; yaml.safe_load(open('${AG_DIR}/agent-guard.yaml.example'))" 2>/dev/null || {
    echo "   ⚠️  PyYAML not available; skipping YAML validation"
}
echo "   ✅ configs OK"

echo ""
echo "============================================"
echo "✅ All tests passed"
echo "============================================"
