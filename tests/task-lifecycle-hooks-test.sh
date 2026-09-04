#!/usr/bin/env bash
#
# Testes de contrato para hooks de task lifecycle.
# Integração leve: cria repositório git temporário com um linked worktree,
# instala hooks e verifica transições automáticas de estado na nota do slot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0
FAIL=0
ok() { local desc="$1"; PASS=$((PASS + 1)); printf 'ok   %s\n' "${desc}"; }
bad() { local desc="$1" got="$2"; FAIL=$((FAIL + 1)); printf 'FAIL %s\n     got: %s\n' "${desc}" "${got}"; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

# Cria repositório git principal dentro do sandbox.
REPO="${SANDBOX}/repo"
mkdir -p "${REPO}"
cd "${REPO}"
git init >/dev/null 2>&1
git config user.email "agent-kimi2@hmvip.dev" >/dev/null 2>&1
git config user.name "Agent kimi2" >/dev/null 2>&1

# Copia agent-guard-core para dentro do repo (caminho esperado pelos hooks).
mkdir -p "${REPO}/packages"
cp -r "${SCRIPT_DIR}" "${REPO}/packages/agent-guard-core"

# Configura agent-guard.yaml local.
cat > "${REPO}/agent-guard.yaml" <<'EOF'
---
project:
  name: test
  domain: hmvip.dev
paths:
  main_repo: ""
  base_dir: ""
  package_root: packages/agent-guard-core
  session_storage: .kiro/locks/agent-sessions
  init_script: .hmvip-agent-init
identities:
  kimi:
    slots: 7
    max_slots: 20
    auto_expand: true
    worktree_prefix: hmvip-ia-kimi
    author_email: agent-kimi{n}@hmvip.dev
    author_name: HMVIP Kimi{n} Agent
git:
  protected_branches:
    - develop
    - main
  base_branch: develop
  notes_ref: refs/notes/agent-guard-worktree
EOF

# Cria diretório de tarefas e nota legada.
mkdir -p "${REPO}/.agent-guard/tasks"
note_path="${REPO}/.agent-guard/tasks/kimi2.md"
cat > "${note_path}" <<'EOF'
# Slot kimi2

Próximo passo: implementar feature.
EOF
chmod 600 "${note_path}"

# Commit inicial no repo principal (necessário para worktree).
echo "root" > root.txt
git add root.txt agent-guard.yaml packages/agent-guard-core .agent-guard/tasks/kimi2.md >/dev/null 2>&1 || true
git commit -m "initial" >/dev/null 2>&1 || true

# Cria bare repo falso como origin para que o hook pre-push consiga enviar notes.
ORIGIN="${SANDBOX}/origin.git"
git init --bare "${ORIGIN}" >/dev/null 2>&1
git remote add origin "${ORIGIN}" >/dev/null 2>&1
git push origin develop >/dev/null 2>&1 || true

# Cria worktree vinculado com nome reconhecido pelo hook.
worktree="${REPO}/hmvip-ia-kimi2"
git worktree add "${worktree}" -b ia-kimi2/ia-a/hook-test >/dev/null 2>&1 || true
git -C "${worktree}" remote add origin "${ORIGIN}" >/dev/null 2>&1 || true
git -C "${worktree}" config user.email "agent-kimi2@hmvip.dev" >/dev/null 2>&1
git -C "${worktree}" config user.name "Agent kimi2" >/dev/null 2>&1

# Source helpers para criar nota estruturada depois.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/src/task-lifecycle.sh"

# ---------------------------------------------------------------------------
# 1) post-commit move planning -> coding no primeiro commit
# ---------------------------------------------------------------------------
# Converte nota legada para estruturada em planning.
_task_create "kimi2" "Hook test" "ia-kimi2/ia-a/hook-test" "${note_path}"
state="$(_task_get_field "${note_path}" "state")"
[[ "${state}" == "planning" ]] || { bad "nota inicial em planning" "${state}"; exit 1; }

# Simula o hook post-commit dentro do linked worktree.
cd "${worktree}"
echo "first" > file.txt
git add file.txt >/dev/null 2>&1
git commit -m "first commit" >/dev/null 2>&1

AGENT_GUARD_REPO_ROOT="${REPO}" bash "${REPO}/packages/agent-guard-core/hooks/post-commit" >/dev/null 2>&1 || true

state="$(_task_get_field "${note_path}" "state")"
if [[ "${state}" == "coding" ]]; then
    ok "post-commit move planning -> coding no primeiro commit"
else
    bad "post-commit move planning -> coding" "${state}"
fi

# ---------------------------------------------------------------------------
# 2) post-commit não altera estado quando já está em coding
# ---------------------------------------------------------------------------
state="$(_task_get_field "${note_path}" "state")"
[[ "${state}" == "coding" ]] || { bad "nota em coding antes do segundo commit" "${state}"; exit 1; }

echo "second" >> file.txt
git add file.txt >/dev/null 2>&1
git commit -m "second commit" >/dev/null 2>&1

AGENT_GUARD_REPO_ROOT="${REPO}" bash "${REPO}/packages/agent-guard-core/hooks/post-commit" >/dev/null 2>&1 || true

state="$(_task_get_field "${note_path}" "state")"
if [[ "${state}" == "coding" ]]; then
    ok "post-commit mantém coding em commits subsequentes"
else
    bad "post-commit mantém coding" "${state}"
fi

# ---------------------------------------------------------------------------
# 3) pre-push move coding -> review quando há PR aberto
# ---------------------------------------------------------------------------
# Cria gh falso no PATH para simular PR aberto sem depender do GitHub CLI real.
FAKE_BIN="${SANDBOX}/bin"
mkdir -p "${FAKE_BIN}"
cat > "${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo -e "42\tTest PR\tia-kimi2/ia-a/hook-test"
fi
exit 0
EOF
chmod +x "${FAKE_BIN}/gh"
export PATH="${FAKE_BIN}:${PATH}"

# Simula stdin do hook pre-push: origin develop..HEAD.
AGENT_GUARD_REPO_ROOT="${REPO}" bash "${REPO}/packages/agent-guard-core/hooks/pre-push" origin develop <<'EOF' >/dev/null || true
develop 0000000000000000000000000000000000000000 0000000000000000000000000000000000000000
EOF

state="$(_task_get_field "${note_path}" "state")"
if [[ "${state}" == "review" ]]; then
    ok "pre-push move coding -> review com PR aberto"
else
    bad "pre-push move coding -> review" "${state}"
fi

# ---------------------------------------------------------------------------
# 4) pre-push atualiza lista de PRs na nota
# ---------------------------------------------------------------------------
prs="$(_task_get_field "${note_path}" "prs")"
if [[ "${prs}" == *"42"* ]]; then
    ok "pre-push atualiza lista de PRs na nota"
else
    bad "pre-push atualiza lista de PRs" "${prs}"
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
    echo "✅ All task lifecycle hook tests passed (${PASS} checks)."
    exit 0
else
    echo "❌ ${FAIL} task lifecycle hook test(s) failed (${PASS} passed)."
    exit 1
fi
