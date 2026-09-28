#!/usr/bin/env bash
#
# Testes de contrato do VERIFICATION register (F0-F S3) — v5 PÓS-#7609.
#
# Modelo vigente (OWNER DECISION 2026-09-13): verificador independente =
# CI determinístico (required checks + Merge Queue); G1 = classificação
# observacional de risco (não-gate); ZERO attestation manual. verify/--check
# READ-ONLY derivam VERIFIED/REJECTED/UNKNOWN de: run ativo S2 + manifest
# (verification.md, não-autoritativo) + evidence real/tracked + HEAD vivo +
# required checks aplicáveis à base (incl. Agent Governance inteiro) +
# boundaries + rollback.
#
# Hermeticidade: monkeypatch IN-PROCESS das funções `_vgh_*` de I/O
# (inacessível pelo CLI operacional); G1 do checkout sob teste (relativo).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
G1_FROM_TREE="${REPO_ROOT}/.github/scripts/pr-critical-review-gate.sh"
TEMPLATE_VMD="${REPO_ROOT}/.kiro/runs/TEMPLATE-run/verification.md"
[[ -f "${G1_FROM_TREE}" && -f "${TEMPLATE_VMD}" ]] || { echo "FAIL: tree sob teste incompleto"; exit 1; }

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/src/verify.sh"
# shellcheck source=/dev/null
source "${G1_FROM_TREE}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# Setup: repo principal + DOIS worktrees reais
# ---------------------------------------------------------------------------

MAIN="${TMP_DIR}/main"
SESS="${TMP_DIR}/sessions"
git init -q "${MAIN}"
git -C "${MAIN}" config user.email "agent-kimi1@example.com"
git -C "${MAIN}" config user.name "Test"
echo "identities:" > "${MAIN}/agent-guard.yaml"
echo "  kimi:" >> "${MAIN}/agent-guard.yaml"
echo "    slots: 3" >> "${MAIN}/agent-guard.yaml"
echo "    max_slots: 10" >> "${MAIN}/agent-guard.yaml"
git -C "${MAIN}" add agent-guard.yaml
git -C "${MAIN}" commit -q -m "config"
git -C "${MAIN}" worktree add -q "${TMP_DIR}/wt-kimi2" -b ia-kimi2/ia-a/verify-test 2>/dev/null
git -C "${MAIN}" worktree add -q "${TMP_DIR}/wt-kimi3" -b ia-kimi3/ia-a/verify-review 2>/dev/null
WT2="${TMP_DIR}/wt-kimi2"
WT3="${TMP_DIR}/wt-kimi3"
git -C "${WT2}" config user.email "agent-kimi2@example.com"
git -C "${WT3}" config user.email "agent-kimi3@example.com"

make_lease() {
    local session_dir="$1" identity="$2" worktree="$3"
    mkdir -p "${session_dir}"
    cat > "${session_dir}/${identity}.json" <<EOF
{"status": "active", "worktree_path": "${worktree}", "pid": 999999, "branch": "ia-${identity}/ia-a/test", "role": "ia-a"}
EOF
}
make_lease "${SESS}" "kimi2" "${WT2}"
make_lease "${SESS}" "kimi3" "${WT3}"

export AGENT_GUARD_CLAIM_SESSION_DIR="${SESS}"
export AGENT_GUARD_REPO_ROOT="${MAIN}"

run_claim() {
    local wt="$1" identity="$2"; shift 2
    (
        cd "${wt}"
        export AGENT_GUARD_CLAIM_IDENTITY="${identity}"
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/src/claim.sh"
        _claim_cli_main "$@"
    )
}

# ---------------------------------------------------------------------------
# Monkeypatch in-process das autoridades GitHub
# ---------------------------------------------------------------------------

MP_HEAD="" MP_REF="" MP_BASE="develop" MP_LABELS="" MP_CHECKS="" MP_FILES="" MP_BP=""

RULESET_A="${TMP_DIR}/ruleset-1.json"
cat > "${RULESET_A}" <<'EOF'
{"name": "Proteção Básica", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/heads/develop", "~DEFAULT_BRANCH"]}},
 "rules": [{"type": "required_status_checks", "parameters": {"required_status_checks": [
   {"context": "PHP Syntax Validation"},
   {"context": "Validate Action Scheduler Hooks"},
   {"context": "Validate AI Assistant Guide Mode Contract"},
   {"context": "Quality Gates (G2-G9)"},
   {"context": "Agent Governance"}]}}]}
EOF
RULESET_B="${TMP_DIR}/ruleset-2.json"
cat > "${RULESET_B}" <<'EOF'
{"name": "Release", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/heads/release/*"]}},
 "rules": [{"type": "required_status_checks", "parameters": {"required_status_checks": [
   {"context": "Release Check"}]}}]}
EOF

run_v3() {
    local wt="$1"; shift
    (
        cd "${wt}"
        export AGENT_GUARD_CLAIM_SESSION_DIR="${SESS}"
        export AGENT_GUARD_REPO_ROOT="${MAIN}"
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/src/verify.sh"
        # shellcheck source=/dev/null
        source "${G1_FROM_TREE}"
        _verify_source_classifier() { return 0; }
        _vgh_pr_meta() { printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "${MP_HEAD}" "${MP_REF}" "hmvip-bot" "${MP_LABELS:-}" "${MP_BASE}"; }
        _vgh_checks_tsv() { printf '%s' "${MP_CHECKS:-}"; }
        _vgh_pr_files() { printf '%s' "${MP_FILES:-}"; }
        _vgh_branch_protection_contexts() { printf '%s' "${MP_BP:-}"; }
        _vgh_default_branch() { printf 'develop\n'; }
        _vgh_ruleset_ids() { printf '1\n2\n'; }
        [[ -n "${V3_EXTRA:-}" ]] && source "${V3_EXTRA}"
        _vgh_ruleset_detail() {
            case "${1}" in
                1) cat "${RULESET_A}" ;;
                2) cat "${RULESET_B}" ;;
                *) return 1 ;;
            esac
        }
        _verify_cli_main "$@"
    )
}

CHECKS_ALL_GREEN=$'PHP Syntax Validation\tsuccess\thttps://ci/1\nValidate Action Scheduler Hooks\tsuccess\thttps://ci/2\nValidate AI Assistant Guide Mode Contract\tsuccess\thttps://ci/3\nQuality Gates (G2-G9)\tsuccess\thttps://ci/4\nAgent Governance\tsuccess\thttps://ci/5'
CHECKS_AG_RED=$'PHP Syntax Validation\tsuccess\thttps://ci/1\nValidate Action Scheduler Hooks\tsuccess\thttps://ci/2\nValidate AI Assistant Guide Mode Contract\tsuccess\thttps://ci/3\nQuality Gates (G2-G9)\tsuccess\thttps://ci/4\nAgent Governance\tfailure\thttps://ci/5'
CHECKS_PHP_RED=$'PHP Syntax Validation\tfailure\thttps://ci/1\nValidate Action Scheduler Hooks\tsuccess\thttps://ci/2\nValidate AI Assistant Guide Mode Contract\tsuccess\thttps://ci/3\nQuality Gates (G2-G9)\tsuccess\thttps://ci/4\nAgent Governance\tsuccess\thttps://ci/5'
CHECKS_PHP_ONLY=$'PHP Syntax Validation\tsuccess\thttps://ci/1'

# ---------------------------------------------------------------------------
# Helpers de TASK/run
# ---------------------------------------------------------------------------

make_task_file() {
    local task_id="$1"
    mkdir -p "${WT2}/.kiro/tasks/202609"
    cat > "${WT2}/.kiro/tasks/202609/${task_id}.md" <<EOF
---
task_id: ${task_id}
owner: kimi2
risk_class: low
---
EOF
}

CLAIMED=""
claim_task() {
    local task_id="$1"
    make_task_file "${task_id}"
    run_claim "${WT2}" "kimi2" "${task_id}" \
        --branch ia-kimi2/ia-a/verify-test --confidence alta >/dev/null
    CLAIMED="${task_id}"
    RUN_DIR="${WT2}/.kiro/runs/${task_id}/01"
}

commit_run() {
    git -C "${WT2}" add -A
    git -C "${WT2}" commit -q --allow-empty -m "run: ${CLAIMED} verification state"
}

# set_row_status_evidence <vmd> <row> <status> <evidence>
set_row_status_evidence() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import re, sys
p, n, st, ev = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
c = open(p).read().split("\n")
out = []
for ln in c:
    if re.match(r"^\| %s \|" % re.escape(n), ln):
        parts = ln.split("|")
        if len(parts) >= 6:
            parts[3] = " %s " % st
            parts[4] = " %s " % ev
            ln = "|".join(parts)
    out.append(ln)
open(p, "w").write("\n".join(out))
PY
}

# write_manifest_from_template <run_dir> <task_id> <seq> — EXATAMENTE uma
# cópia preenchida do TEMPLATE canônico (manifest não-autoritativo).
write_manifest_from_template() {
    local run_dir="$1" task_id="$2" seq="$3"
    mkdir -p "${run_dir}/evidence"
    local bundle="${run_dir}/evidence/bundle.tar.gz"
    printf 'conteudo real do artefato de evidencia\n' > "${bundle}"
    local digest
    digest="$(sha256sum "${bundle}" | awk '{print $1}')"
    printf '%s  bundle.tar.gz\n' "${digest}" > "${run_dir}/evidence/hashes.sha256"
    printf 'done_criterion 1 satisfeito; diff em docs/change.md; sem deploy\n' > "${run_dir}/evidence/done.md"
    printf 're-check executado via CI deterministico (required checks) no HEAD\n' > "${run_dir}/evidence/recheck.md"
    printf 'boundaries respeitados: sem AWS/prod/deploy; escopo docs-only\n' > "${run_dir}/evidence/boundary.md"
    sed -e "s/<TASK-YYYYMMDD-NN>/${task_id}/" \
        -e "s/<01>/${seq}/" \
        -e "s/<slot-executor>/kimi2/" \
        -e "s/<ISO-8601>/2026-09-13T00:00:00+00:00/" \
        "${TEMPLATE_VMD}" > "${run_dir}/verification.md"
    set_row_status_evidence "${run_dir}/verification.md" 1 "PASS" "./evidence/done.md"
    set_row_status_evidence "${run_dir}/verification.md" 2 "PASS" "https://ci/1"
    set_row_status_evidence "${run_dir}/verification.md" 3 "PASS" "./evidence/hashes.sha256"
    set_row_status_evidence "${run_dir}/verification.md" 4 "PASS" "./evidence/recheck.md"
    set_row_status_evidence "${run_dir}/verification.md" 5 "PASS" "./evidence/boundary.md"
    set_row_status_evidence "${run_dir}/verification.md" 6 "N-A" "docs/rollback.md"
}

release_claimed() {
    [[ -z "${CLAIMED}" ]] && return 0
    run_claim "${WT2}" "kimi2" --release "${CLAIMED}" >/dev/null 2>&1 || {
        echo "FAIL: release de ${CLAIMED} falhou"; exit 1
    }
    CLAIMED=""
}

git_clean_hash() { git -C "${WT2}" status --porcelain; git -C "${WT2}" rev-parse HEAD; }

setup_task() {
    claim_task "$1"
    write_manifest_from_template "${RUN_DIR}" "${CLAIMED}" "01"
    commit_run
    local h
    h="$(git -C "${WT2}" rev-parse HEAD)"
    MP_HEAD="${h}" MP_REF="ia-kimi2/ia-a/verify-test" MP_BASE="develop" MP_LABELS=""
    MP_CHECKS="${CHECKS_ALL_GREEN}"
    MP_FILES=$'docs/change.md'
}

# ==========================================================================
# TESTE E2E FINAL — sem attestation manual em nenhum passo
# ==========================================================================

echo "E2E) template canônico + estado commitado + checks verdes (incl. AG) => VERIFIED read-only"
setup_task TASK-E2E-01
before="$(git_clean_hash)"
out="$(run_v3 "${WT2}" "${CLAIMED}" --pr 60 2>&1)" \
    || { echo "FAIL: e2e rejeitado: ${out}"; exit 1; }
grep -q "VERIFY_STATE=VERIFIED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
grep -q "risk_metadata" <<< "${out}" || { echo "FAIL: metadata observacional ausente: ${out}"; exit 1; }
grep -q "Agent Governance=green" <<< "${out}" || { echo "FAIL: AG inteiro não exigido: ${out}"; exit 1; }
! grep -q "Release Check" <<< "${out}" || { echo "FAIL: check de outra base exigido: ${out}"; exit 1; }
after="$(git_clean_hash)"
[[ "${before}" == "${after}" ]] || { echo "FAIL: verify não é read-only"; exit 1; }
[[ -z "$(git -C "${WT2}" status --porcelain)" ]] || { echo "FAIL: worktree sujo"; exit 1; }
echo "   OK (manifest canônico; verificador = CI determinístico; zero attestation; read-only)"

echo "E2E-AG) checks verdes MAS Agent Governance FAILURE => NÃO VERIFIED"
MP_CHECKS="${CHECKS_AG_RED}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 60 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"Agent Governance=failure"* ]] || { echo "FAIL: ${out}"; exit 1; }
MP_CHECKS="${CHECKS_ALL_GREEN}"
echo "   OK"

echo "E2E-10/11) push H2: checks ainda não verdes => não VERIFIED; verdes => VERIFIED (sem attestation)"
git -C "${WT2}" commit -q --allow-empty -m "push novo"
H2="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H2}"
MP_CHECKS="${CHECKS_PHP_RED}"   # checks do H2 ainda não verdes
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 60 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: H2 com checks vermelhos retornou VERIFIED"; exit 1; }
grep -q "VERIFY_STATE=REJECTED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
MP_CHECKS="${CHECKS_ALL_GREEN}" # checks H2 verdes
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 60 2>&1)" \
    || { echo "FAIL: H2 checks verdes: ${out}"; exit 1; }
grep -q "VERIFY_STATE=VERIFIED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
echo "   OK"
release_claimed

# ==========================================================================
# LIVE: mesmo SHA — check regredido => não VERIFIED
# ==========================================================================

echo "LIVE-B) required check rerun=failure no MESMO H => não VERIFIED"
setup_task TASK-LIVE-B
MP_CHECKS="${CHECKS_PHP_RED}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 61 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"PHP Syntax Validation=failure"* ]] || { echo "FAIL: ${out}"; exit 1; }
echo "   OK"
release_claimed

# ==========================================================================
# Binding Git real ao HEAD vivo (A–E)
# ==========================================================================

echo "BIND-A) verification.md modificado localmente depois => FAIL"
setup_task TASK-BIND-A
echo "alteracao pos-verificacao" >> "${RUN_DIR}/verification.md"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 62 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"verification.md untracked/dirty"* ]] || { echo "FAIL: A: ${out}"; exit 1; }
echo "   OK"
release_claimed

echo "BIND-B) evidence untracked criada depois => FAIL"
setup_task TASK-BIND-B
set_row_status_evidence "${RUN_DIR}/verification.md" 3 "PASS" "./evidence/late.md"
printf 'evidencia tardia nao commitada\n' > "${RUN_DIR}/evidence/late.md"
git -C "${WT2}" add "${RUN_DIR}/verification.md"
git -C "${WT2}" commit -q -m "vmd referencia late.md (evidence untracked)"
H_B="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_B}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 63 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"condição 3"* ]] || { echo "FAIL: B: ${out}"; exit 1; }
echo "   OK"
release_claimed

echo "BIND-C) evidence tracked mas dirty => FAIL"
setup_task TASK-BIND-C
echo "dirty" >> "${RUN_DIR}/evidence/hashes.sha256"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 64 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"condição 3"* ]] || { echo "FAIL: C: ${out}"; exit 1; }
echo "   OK"
release_claimed

echo "BIND-D) claim.branch != PR head.ref => FAIL"
setup_task TASK-BIND-D
MP_REF="ia-kimi9/ia-a/outra-branch"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 65 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"claim.branch"* ]] || { echo "FAIL: D: ${out}"; exit 1; }
echo "   OK"
release_claimed

echo "BIND-E) frontmatter task_id divergente => FAIL"
setup_task TASK-BIND-E
sed -i 's/^task_id: .*/task_id: TASK-OUTRA/' "${RUN_DIR}/verification.md"
git -C "${WT2}" add "${RUN_DIR}/verification.md"
git -C "${WT2}" commit -q -m "frontmatter divergente"
H_E="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_E}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 66 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"task_id/run_seq divergentes"* ]] || { echo "FAIL: E: ${out}"; exit 1; }
echo "   OK"
release_claimed

# ==========================================================================
# Manifest não-autoritativo: campo legado de verdict é ignorado
# ==========================================================================

echo "MANIFEST) manifest com campo legado verdict: REJECTED é IGNORADO — estado é derivado"
setup_task TASK-MANIFEST-1
# injeta campo legado no frontmatter (manifest do template não o tem)
sed -i 's/^prepared_at: .*/prepared_at: 2026-09-13T00:00:00+00:00\nverdict: REJECTED/' "${RUN_DIR}/verification.md"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "campo legado"
H_M="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_M}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 67 2>&1)" \
    || { echo "FAIL: campo legado bloqueou: ${out}"; exit 1; }
grep -q "VERIFY_STATE=VERIFIED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
# condição FAIL no manifest => REJECTED derivado
set_row_status_evidence "${RUN_DIR}/verification.md" 4 "FAIL" "./evidence/recheck.md"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "condicao FAIL"
H_M="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_M}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 67 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"VERIFY_STATE=REJECTED"* ]] || { echo "FAIL: ${out}"; exit 1; }
echo "   OK"
release_claimed

# ==========================================================================
# Evidência vazia / whitespace / placeholder / sha256
# ==========================================================================

echo "EVID) empty/whitespace/placeholder => FAIL"
setup_task TASK-EVID-1
: > "${RUN_DIR}/evidence/done.md"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "evidence vazia"
H_Z="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_Z}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 68 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"condição 1"* ]] || { echo "FAIL: empty: ${out}"; exit 1; }
printf '   \n\t\n' > "${RUN_DIR}/evidence/done.md"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "whitespace"
H_Z="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_Z}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 68 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: whitespace aceito"; exit 1; }
set_row_status_evidence "${RUN_DIR}/verification.md" 4 "PASS" "<preencher>"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "placeholder"
H_Z="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_Z}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 68 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: placeholder aceito"; exit 1; }
echo "   OK"
release_claimed

echo "SHA256) digest errado / artifact inexistente / untracked / malformed / escape => FAIL; correto => PASS"
setup_task TASK-SHA-1
# digest errado
BUNDLE="${RUN_DIR}/evidence/bundle.tar.gz"
printf '0000000000000000000000000000000000000000000000000000000000000000  bundle.tar.gz\n' > "${RUN_DIR}/evidence/hashes.sha256"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "digest errado"
H_S="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_S}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 69 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"condição 3"* ]] || { echo "FAIL: digest errado: ${out}"; exit 1; }
# artifact inexistente
printf '%s  nao-existe.tar.gz\n' "$(sha256sum "${BUNDLE}" | awk '{print $1}')" > "${RUN_DIR}/evidence/hashes.sha256"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "artifact inexistente"
H_S="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_S}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 69 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: artifact inexistente aceito"; exit 1; }
# malformed
printf 'isso nao e um sha256 manifest\n' > "${RUN_DIR}/evidence/hashes.sha256"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "malformed"
H_S="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_S}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 69 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: malformed aceito"; exit 1; }
# path escape
printf '%s  ../outside.tar.gz\n' "$(sha256sum "${BUNDLE}" | awk '{print $1}')" > "${RUN_DIR}/evidence/hashes.sha256"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "escape"
H_S="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_S}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 69 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: escape aceito"; exit 1; }
# untracked: artifact novo referenciado mas nao commitado
printf '%s  bundle.tar.gz\n' "$(sha256sum "${BUNDLE}" | awk '{print $1}')" > "${RUN_DIR}/evidence/hashes.sha256"
printf 'novo artifact real\n' > "${RUN_DIR}/evidence/novo.bin"
sed -i "s#bundle.tar.gz#novo.bin#" "${RUN_DIR}/evidence/hashes.sha256"
git -C "${WT2}" add "${RUN_DIR}/verification.md" "${RUN_DIR}/evidence/hashes.sha256"
git -C "${WT2}" commit -q -m "vmd+sha256 committed; artifact untracked"
H_S="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_S}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 69 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: artifact untracked aceito"; exit 1; }
# positivo: artifact commitado + digest correto (recomputado sobre novo.bin)
printf '%s  novo.bin
' "$(sha256sum "${RUN_DIR}/evidence/novo.bin" | awk '{print $1}')" > "${RUN_DIR}/evidence/hashes.sha256"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "artifact tracked"
H_S="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_S}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 69 2>&1)" \
    || { echo "FAIL: positivo sha256: ${out}"; exit 1; }
grep -q "VERIFY_STATE=VERIFIED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
# binário: formato "<hash> *name" (sha256sum -b) também é aceito
printf '%s *novo.bin\n' "$(sha256sum "${RUN_DIR}/evidence/novo.bin" | awk '{print $1}')" > "${RUN_DIR}/evidence/hashes.sha256"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "sha256 formato binario"
H_S="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_S}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 69 2>&1)" \
    || { echo "FAIL: binario valido rejeitado: ${out}"; exit 1; }
grep -q "VERIFY_STATE=VERIFIED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
# malformed: '<hash>*name' (sem espaço no char 64) => FAIL
printf '%s*novo.bin\n' "$(sha256sum "${RUN_DIR}/evidence/novo.bin" | awk '{print $1}')" > "${RUN_DIR}/evidence/hashes.sha256"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "sha256 malformed binario"
H_S="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_S}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 69 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: '<hash>*name' aceito"; exit 1; }
echo "   OK"
release_claimed

# ==========================================================================
# Rollback N-A só docs-only; CRITICAL/label são metadata não-gate
# ==========================================================================

echo "ROLLBACK) src/*.sh + N-A => FAIL; code + rollback PASS/tracked => VERIFIED"
claim_task TASK-ROLLBACK-1
write_manifest_from_template "${RUN_DIR}" "${CLAIMED}" "01"
commit_run
H_R="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_R}" MP_REF="ia-kimi2/ia-a/verify-test" MP_BASE="develop" MP_LABELS=""
MP_CHECKS="${CHECKS_ALL_GREEN}"
MP_FILES=$'packages/agent-guard-core/src/novo.sh'
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 70 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"condição #6 (rollback) N-A inadmissível"* ]] \
    || { echo "FAIL: N-A aceito em PR de código: ${out}"; exit 1; }
set_row_status_evidence "${RUN_DIR}/verification.md" 6 "PASS" "./evidence/rollback.md"
printf 'rollback: revert do commit <sha> restabelece o estado anterior\n' > "${RUN_DIR}/evidence/rollback.md"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "rollback PASS tracked"
H_R="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_R}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 70 2>&1)" \
    || { echo "FAIL: code + rollback: ${out}"; exit 1; }
grep -q "VERIFY_STATE=VERIFIED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
echo "   OK"
release_claimed

echo "META) CRITICAL + label needs-independent-verify = metadata NÃO-gate => VERIFIED"
setup_task TASK-META-1
# PR toca código => rollback deve ser PASS (mesma regra de sempre)
set_row_status_evidence "${RUN_DIR}/verification.md" 6 "PASS" "./evidence/rollback.md"
printf 'rollback: revert do commit restabelece o estado anterior\n' > "${RUN_DIR}/evidence/rollback.md"
git -C "${WT2}" add -A
git -C "${WT2}" commit -q -m "rollback para META"
H_META="$(git -C "${WT2}" rev-parse HEAD)"
MP_HEAD="${H_META}"
MP_FILES=$'packages/agent-guard-core/src/init.sh'   # classificação CRITICAL
MP_LABELS="needs-independent-verify"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 71 2>&1)" \
    || { echo "FAIL: CRITICAL/label bloqueou: ${out}"; exit 1; }
grep -q "VERIFY_STATE=VERIFIED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
grep -q "classification=CRITICAL" <<< "${out}" || { echo "FAIL: metadata ausente: ${out}"; exit 1; }
echo "   OK"
release_claimed

# ==========================================================================
# Checks required completos + escopo de base
# ==========================================================================

echo "REQUIRED) só PHP Syntax verde, demais ausentes => NÃO VERIFIED"
setup_task TASK-REQ-1
MP_CHECKS="${CHECKS_PHP_ONLY}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 72 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"MISSING"* ]] || { echo "FAIL: ${out}"; exit 1; }
echo "   OK"

echo "SCOPE) ruleset release/* não se aplica a base develop (e vice-versa)"
MP_BASE="release/1.0"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 72 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"Release Check=MISSING"* ]] || { echo "FAIL: ${out}"; exit 1; }
MP_BASE="develop"
echo "   OK"
release_claimed

# ==========================================================================
# Autoridade efetiva completa: rulesets UNION branch protection
# ==========================================================================

echo "EFFECTIVE_REQUIRED) branch protection acrescenta Fresh Install Smoke; vermelho => NÃO VERIFIED; 6 verdes => VERIFIED"
setup_task TASK-BP-1
MP_BP="Fresh Install Smoke"
CHECKS_FIS_RED="${CHECKS_ALL_GREEN}"$'\nFresh Install Smoke\tfailure\thttps://ci/6'
CHECKS_SIX_GREEN="${CHECKS_ALL_GREEN}"$'\nFresh Install Smoke\tsuccess\thttps://ci/6'
MP_CHECKS="${CHECKS_FIS_RED}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 72 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"Fresh Install Smoke=failure"* ]] || { echo "FAIL: ${out}"; exit 1; }
MP_CHECKS="${CHECKS_SIX_GREEN}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 72 2>&1)" \
    || { echo "FAIL: 6 verdes rejeitados: ${out}"; exit 1; }
grep -q "VERIFY_STATE=VERIFIED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
# FIS ausente dos checks mas exigido pela branch protection => MISSING
MP_CHECKS="${CHECKS_ALL_GREEN}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 72 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"Fresh Install Smoke=MISSING"* ]] || { echo "FAIL: ${out}"; exit 1; }
MP_CHECKS="${CHECKS_ALL_GREEN}" MP_BP=""
echo "   OK"
release_claimed

# ==========================================================================
# Classificador fail-closed (helper canônico safe)
# ==========================================================================

echo "CLASSIFIER_SAFE) files vazio / crash / output inválido => UNKNOWN (fail-closed)"
setup_task TASK-CLS-1
# files vazio
MP_FILES=""
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 72 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"VERIFY_STATE=UNKNOWN"* ]] || { echo "FAIL(files vazio): ${out}"; exit 1; }
# crash + output inválido: mesmo harness, classifier redefinido
CRASH_SRC="${TMP_DIR}/classifier-crash.sh"
cat > "${CRASH_SRC}" <<'EOF'
pr_classify_files_critical() { echo "CRITICALX"; return 3; }
EOF
V3_EXTRA="${CRASH_SRC}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 72 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"VERIFY_STATE=UNKNOWN"* ]] || { echo "FAIL(crash): ${out}"; exit 1; }
# rc=0 + NON_CRITICAL (rc inesperado para o classificador canônico) => UNKNOWN
NC_SRC="${TMP_DIR}/classifier-noncritical.sh"
cat > "${NC_SRC}" <<'EOF'
pr_classify_files_critical() { echo "NON_CRITICAL"; return 0; }
EOF
V3_EXTRA="${NC_SRC}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 72 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"VERIFY_STATE=UNKNOWN"* ]] || { echo "FAIL(rc inesperado): ${out}"; exit 1; }
V3_EXTRA="" MP_FILES=$'docs/change.md'
# válido continua apenas metadata não-gate
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 72 2>&1)" \
    || { echo "FAIL: válido rejeitado: ${out}"; exit 1; }
grep -q "VERIFY_STATE=VERIFIED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
echo "   OK"
release_claimed

# ==========================================================================
# Representação realista de base_ref (PR API devolve "develop"; conditions
# usam "refs/heads/...") — avaliador puro
# ==========================================================================

echo "REAL_REF) base_ref='develop' casa com refs/heads/develop; release/*; não-casamento"
(
    source "${SCRIPT_DIR}/src/verify.sh"
    rs_develop='{"enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/develop"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Ctx"}]}}]}'
    rs_release='{"enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/release/*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Ctx"}]}}]}'
    rs_default='{"enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Ctx"}]}}]}'
    out="$(_vgh_ruleset_contexts develop develop <<< "${rs_develop}")"
    [[ "${out}" == "Ctx" ]] || { echo "FAIL: develop vs refs/heads/develop: «${out}»" >&2; exit 1; }
    out="$(_vgh_ruleset_contexts release/1.0 develop <<< "${rs_release}")"
    [[ "${out}" == "Ctx" ]] || { echo "FAIL: release/1.0 vs release/*: «${out}»" >&2; exit 1; }
    out="$(_vgh_ruleset_contexts develop develop <<< "${rs_release}")"
    [[ -z "${out}" ]] || { echo "FAIL: develop casou com release/*: «${out}»" >&2; exit 1; }
    out="$(_vgh_ruleset_contexts develop develop <<< "${rs_default}")"
    [[ "${out}" == "Ctx" ]] || { echo "FAIL: ~DEFAULT_BRANCH/develop: «${out}»" >&2; exit 1; }
    out="$(_vgh_ruleset_contexts main develop <<< "${rs_default}")"
    [[ -z "${out}" ]] || { echo "FAIL: ~DEFAULT_BRANCH/main casou: «${out}»" >&2; exit 1; }
)
[[ $? -eq 0 ]] || exit 1
echo "   OK"

# ==========================================================================
# Paginação completa (checks)
# ==========================================================================

echo "PAGE) required failure na página 2 (>100 checks) => NÃO VERIFIED; sem falhas => VERIFIED"
setup_task TASK-PAGE-1
{
    for i in $(seq 1 120); do
        printf 'Check Opcional %03d\tsuccess\thttps://ci/opt/%03d\n' "${i}" "${i}"
    done
    printf 'Quality Gates (G2-G9)\tfailure\thttps://ci/4\n'
} > "${TMP_DIR}/checks-paged.txt"
MP_CHECKS="$(cat "${TMP_DIR}/checks-paged.txt")"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 73 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"Quality Gates (G2-G9)=failure"* ]] || { echo "FAIL: ${out}"; exit 1; }
MP_CHECKS="${CHECKS_ALL_GREEN}"
out="$(run_v3 "${WT2}" --check "${CLAIMED}" --pr 73 2>&1)" \
    || { echo "FAIL: page verde: ${out}"; exit 1; }
grep -q "VERIFY_STATE=VERIFIED" <<< "${out}" || { echo "FAIL: ${out}"; exit 1; }
echo "   OK"
release_claimed

# ==========================================================================
# Paginação da listagem de rulesets
# ==========================================================================

echo "RULEPAGE) _vgh_ruleset_ids usa gh --paginate (página 2 não é perdida)"
(
    source "${SCRIPT_DIR}/src/verify.sh"
    _vgh_owner_repo() { printf 'hmvip-org hmvip\n'; }
    gh() {
        local seen_paginate=0 url="" arg
        for arg in "$@"; do
            [[ "${arg}" == "--paginate" ]] && seen_paginate=1
            [[ "${arg}" == repos/*rulesets ]] && url="${arg}"
        done
        [[ "${seen_paginate}" -eq 1 && -n "${url}" ]] \
            || { echo "FAIL: gh sem --paginate em ${url}" >&2; return 9; }
        # Emula agregação de páginas + aplicação do --jq (.[] | ... | .id)
        printf '%s\n' '[{"id": 1}]' '[{"id": 2}]' | grep -o '"id": [0-9]*' | grep -o '[0-9]*'
    }
    ids="$(_vgh_ruleset_ids)" || { echo "FAIL: _vgh_ruleset_ids rc" >&2; exit 1; }
    [[ "${ids}" == $'1\n2' ]] || { echo "FAIL: ids=«${ids}»" >&2; exit 1; }
)
[[ $? -eq 0 ]] || exit 1
echo "   OK"

# ==========================================================================
# Run ativo S2 (incl. supersession com históricos released)
# ==========================================================================

echo "RUNSEL-A) 01 active <- 02 supersedes; 02 released => 0 active (01 NÃO ressuscita)"
TASK_SS="TASK-SS-A"
BASE_SS="${WT2}/.kiro/runs/${TASK_SS}"
mkdir -p "${BASE_SS}/01" "${BASE_SS}/02"
for seq in 01 02; do
    cat > "${BASE_SS}/${seq}/claim.md" <<EOF
---
task_id: ${TASK_SS}
run_seq: ${seq}
slot: kimi2
branch: ia-kimi2/ia-a/verify-test
claimed_at: 2026-09-13T00:00:00+00:00
confidence: alta
---
EOF
done
printf 'released_by: kimi2\nreleased_at: 2026-09-13T00:00:00+00:00\nreason: teste\n' > "${BASE_SS}/02/.released"
printf 'superseded_run: 01\nsuperseded_slot: kimi2\n' > "${BASE_SS}/02/stale-supersedes"
out="$(cd "${WT2}"; _claim_active_run_dir "${TASK_SS}" 2>/dev/null)" && rc=0 || rc=$?
[[ "${rc}" -eq 1 && -z "${out}" ]] || { echo "FAIL: A rc=${rc} out=${out}"; exit 1; }
echo "   OK"

echo "RUNSEL-B) cadeia 01<-02<-03; 03 released => 0 active"
TASK_SS="TASK-SS-B"
BASE_SS="${WT2}/.kiro/runs/${TASK_SS}"
for seq in 01 02 03; do
    mkdir -p "${BASE_SS}/${seq}"
    cat > "${BASE_SS}/${seq}/claim.md" <<EOF
---
task_id: ${TASK_SS}
run_seq: ${seq}
slot: kimi2
branch: ia-kimi2/ia-a/verify-test
claimed_at: 2026-09-13T00:00:00+00:00
confidence: alta
---
EOF
done
printf 'superseded_run: 01\n' > "${BASE_SS}/02/stale-supersedes"
printf 'superseded_run: 02\n' > "${BASE_SS}/03/stale-supersedes"
printf 'released_by: kimi2\nreleased_at: 2026-09-13T00:00:00+00:00\nreason: teste\n' > "${BASE_SS}/03/.released"
out="$(cd "${WT2}"; _claim_active_run_dir "${TASK_SS}" 2>/dev/null)" && rc=0 || rc=$?
[[ "${rc}" -eq 1 && -z "${out}" ]] || { echo "FAIL: B rc=${rc} out=${out}"; exit 1; }
echo "   OK"

echo "RUNSEL-C/D/E) 01 released + 02 active => 02; dois ativos => CORRUPT; 099/100 numérico"
TASK_SS="TASK-SS-C"
BASE_SS="${WT2}/.kiro/runs/${TASK_SS}"
for seq in 01 02; do
    mkdir -p "${BASE_SS}/${seq}"
    cat > "${BASE_SS}/${seq}/claim.md" <<EOF
---
task_id: ${TASK_SS}
run_seq: ${seq}
slot: kimi2
branch: ia-kimi2/ia-a/verify-test
claimed_at: 2026-09-13T00:00:00+00:00
confidence: alta
---
EOF
done
touch "${BASE_SS}/01/.released"
out="$(cd "${WT2}"; _claim_active_run_dir "${TASK_SS}" 2>/dev/null)" && rc=0 || rc=$?
[[ "${rc}" -eq 0 && "${out}" == *"/02" ]] || { echo "FAIL: C rc=${rc} out=${out}"; exit 1; }
out="$(cd "${WT2}"; _claim_active_run_dir "TASK-SS-B" 2>/dev/null)" && rc=0 || rc=$?
# TASK-SS-B: 01 ainda ativo (só 02,03 foram encadeados; 03 released mas 01 não tem .released e não é superseded por released? 02 supersede 01 e 02 NÃO está released
# => 01 superseded por 02, 02 superseded por 03, 03 released => 0 ativos (A-like)
[[ "${rc}" -eq 1 ]] || { echo "FAIL: D-pre rc=${rc} out=${out}"; exit 1; }
# dois realmente ativos sem supersession => CORRUPT
rm -f "${BASE_SS}/01/.released"
out="$(cd "${WT2}"; _claim_active_run_dir "${TASK_SS}" 2>/dev/null)" && rc=0 || rc=$?
[[ "${rc}" -eq 2 ]] || { echo "FAIL: D rc=${rc} out=${out}"; exit 1; }
# numérico 099/100
TASK_SS="TASK-SS-E"
BASE_SS="${WT2}/.kiro/runs/${TASK_SS}"
for seq in 099 100; do
    mkdir -p "${BASE_SS}/${seq}"
    cat > "${BASE_SS}/${seq}/claim.md" <<EOF
---
task_id: ${TASK_SS}
run_seq: ${seq}
slot: kimi2
branch: ia-kimi2/ia-a/verify-test
claimed_at: 2026-09-13T00:00:00+00:00
confidence: alta
---
EOF
done
touch "${BASE_SS}/099/.released"
out="$(cd "${WT2}"; _claim_active_run_dir "${TASK_SS}" 2>/dev/null)" && rc=0 || rc=$?
[[ "${rc}" -eq 0 && "${out}" == *"/100" ]] || { echo "FAIL: E rc=${rc} out=${out}"; exit 1; }
echo "   OK"

# ==========================================================================
# Bypass por fixtures: env vars NÃO alteram autoridade no caminho real
# ==========================================================================

echo "BYPASS) env vars de fixture não afetam o CLI operacional"
setup_task TASK-BYPASS-1
mkdir -p "${TMP_DIR}/bogus-fx"
echo '{"head":{"sha":"0000000000000000000000000000000000000000"}}' > "${TMP_DIR}/bogus-fx/pulls.json"
out="$(
    cd "${WT2}"
    export AGENT_GUARD_VERIFY_FIXTURE_DIR="${TMP_DIR}/bogus-fx"
    export AGENT_GUARD_VERIFY_G1_SCRIPT="${TMP_DIR}/bogus-fx/g1-falso.sh"
    export AGENT_GUARD_CLAIM_SESSION_DIR="${SESS}"
    export AGENT_GUARD_REPO_ROOT="${MAIN}"
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/src/verify.sh"
    _verify_cli_main "${CLAIMED}" --pr 74 2>&1
)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: env var produziu resultado"; exit 1; }
grep -q "G1 canônico não encontrado" <<< "${out}" \
    || { echo "FAIL: mensagem não é fail-closed: ${out}"; exit 1; }
echo "   OK"
release_claimed

# ==========================================================================
# T11: S2 smoke
# ==========================================================================

echo "T11) S2 smoke: claim => run_seq 01; reclaim => run_seq 02; release limpa"
claim_task TASK-V-11
[[ -f "${RUN_DIR}/claim.md" ]] || { echo "FAIL: claim.md ausente"; exit 1; }
release_claimed
run_claim "${WT2}" "kimi2" "TASK-V-11" --branch ia-kimi2/ia-a/verify-test --confidence alta >/dev/null
[[ -f "${WT2}/.kiro/runs/TASK-V-11/02/claim.md" ]] || { echo "FAIL: reclaim não gerou run_seq 02"; exit 1; }
CLAIMED="TASK-V-11"
release_claimed
out="$(run_claim "${WT2}" "kimi2" --status TASK-V-11 2>&1)" \
    || { echo "FAIL: --status S2 quebrou: ${out}"; exit 1; }
grep -q "UNCLAIMED" <<< "${out}" || { echo "FAIL: release não limpou: ${out}"; exit 1; }
echo "   OK"

echo ""
echo "ALL VERIFY V5 TESTS PASSED"
