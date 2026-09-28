#!/usr/bin/env bash
#
# Testes de contrato do CLAIM lifecycle (F0-F S2, v2 pós independent review).
#
# Cobre os blockers da revisão:
#   A. claim durável no WORKTREE do claimant (linked worktrees reais)
#   B. lease real (sem lease = FAIL; forjado = FAIL)
#   C. concorrência: duas claims simultâneas => exatamente uma vence
#   D. release limpa a nota; release antigo não limpa claim nova
#   E. >1 active => CORRUPT / fail-closed
#   F. shopt nullglob preservado em todas as rotas
#   G. metadata round-trip parser -> update -> writer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/src/claim.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/src/task-lifecycle.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

CLAIM_SH="${SCRIPT_DIR}/src/claim.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_task() {
    local dir="$1" task_id="$2" risk="$3" base_ref="${4:-HEAD}"
    mkdir -p "${dir}/.kiro/tasks/202609"
    cat > "${dir}/.kiro/tasks/202609/${task_id}.md" <<EOF
---
task_id: ${task_id}
owner: kimi2
objective: "objetivo ${task_id}"
done_criteria:
  - "criterio 1"
boundaries:
  - "sem deploy"
base_ref: ${base_ref}
context_refs: []
budget:
  max_turns: 10
  max_time: 1h
risk_class: ${risk}
---
EOF
}

make_lease() {
    local session_dir="$1" identity="$2" worktree="$3" status="${4:-active}"
    mkdir -p "${session_dir}"
    cat > "${session_dir}/${identity}.json" <<EOF
{"status": "${status}", "worktree_path": "${worktree}", "pid": 999999, "branch": "ia-${identity}/ia-a/test", "role": "ia-a"}
EOF
}

run_claim() {
    # roda claim num subshell com identidade/worktree próprios
    local wt="$1" identity="$2" session_dir="$3" repo_root="$4"; shift 4
    (
        cd "${wt}"
        export AGENT_GUARD_CLAIM_IDENTITY="${identity}"
        export AGENT_GUARD_CLAIM_SESSION_DIR="${session_dir}"
        export AGENT_GUARD_REPO_ROOT="${repo_root}"
        # shellcheck source=/dev/null
        source "${CLAIM_SH}"
        _claim_cli_main "$@"
    )
}

# Reconstrução DURÁVEL usando APENAS run dirs/Git (zero lock/journal):
# um run é ativo iff claim.md existe, não tem .released e nenhum run POSTERIOR
# do mesmo TASK o declara em stale-supersedes. Imprime "<count> <claimant>".
durable_state() {
    local task="$1"; shift
    local count=0 claimant="" wt base rd seq_now wt2 base2 rd2 ended
    for wt in "$@"; do
        base="${wt}/.kiro/runs/${task}"
        [[ -d "${base}" ]] || continue
        for rd in "${base}"/*/; do
            [[ -f "${rd}/claim.md" ]] || continue
            [[ -f "${rd}/.released" ]] && continue
            seq_now="$(basename "${rd}")"
            ended=0
            for wt2 in "$@"; do
                base2="${wt2}/.kiro/runs/${task}"
                [[ -d "${base2}" ]] || continue
                for rd2 in "${base2}"/*/; do
                    [[ -f "${rd2}/claim.md" ]] || continue
                    (( 10#$(basename "${rd2}") > 10#${seq_now} )) || continue
                    [[ -f "${rd2}/stale-supersedes" ]] || continue
                    grep -q "superseded_run: ${seq_now}" "${rd2}/stale-supersedes" && ended=1
                done
            done
            [[ "${ended}" -eq 1 ]] && continue
            count=$((count + 1))
            [[ -z "${claimant}" ]] && claimant="$(basename "${wt}")/$(basename "${rd}")"
        done
    done
    echo "${count} ${claimant}"
}

# ---------------------------------------------------------------------------
# Setup: repo principal + 2 linked worktrees + config + sessions
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
git -C "${MAIN}" worktree add -q "${TMP_DIR}/wt-kimi2" -b ia-kimi2/ia-a/claim-test 2>/dev/null
git -C "${MAIN}" worktree add -q "${TMP_DIR}/wt-kimi3" -b ia-kimi3/ia-a/claim-test 2>/dev/null
WT2="${TMP_DIR}/wt-kimi2"
WT3="${TMP_DIR}/wt-kimi3"
git -C "${WT2}" config user.email "agent-kimi2@example.com"
git -C "${WT3}" config user.email "agent-kimi3@example.com"

export AGENT_GUARD_CLAIM_SESSION_DIR="${SESS}"
export AGENT_GUARD_REPO_ROOT="${MAIN}"

make_task "${WT2}" "TASK-20260912-01" "low"
make_task "${WT3}" "TASK-20260912-01" "low"
make_task "${WT2}" "TASK-20260912-TRIVIAL" "trivial"

# ---------------------------------------------------------------------------
# B. lease real
# ---------------------------------------------------------------------------

echo "B1) claim sem lease = FAIL"
if run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-01" >/dev/null 2>&1; then
    echo "FAIL: claim sem lease passou"; exit 1
fi
echo "   OK"

make_lease "${SESS}" "kimi2" "${WT2}"
make_lease "${SESS}" "kimi3" "${WT3}"

echo "B2) claim com lease de outro worktree (forjado) = FAIL"
if run_claim "${WT2}" "kimi3" "${SESS}" "${MAIN}" "TASK-20260912-01" >/dev/null 2>&1; then
    echo "FAIL: identidade forjada passou"; exit 1
fi
echo "   OK"

echo "B3) claim com lease 'released' = FAIL"
make_lease "${SESS}" "kimi2" "${WT2}" "released"
if run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-01" >/dev/null 2>&1; then
    echo "FAIL: claim com lease released passou"; exit 1
fi
echo "   OK"
make_lease "${SESS}" "kimi2" "${WT2}"

echo "B4) claim com lease correto = PASS"
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-01" --branch ia-kimi2/ia-a/claim-test --confidence alta >/dev/null
echo "   OK"

# ---------------------------------------------------------------------------
# A. claim durável no worktree do claimant
# ---------------------------------------------------------------------------

echo "A1) claim.md nasce no worktree do claimant e é visível ao git"
claim_path="${WT2}/.kiro/runs/TASK-20260912-01/01/claim.md"
[[ -f "${claim_path}" ]] || { echo "FAIL: claim.md fora do worktree"; exit 1; }
git -C "${WT2}" status --porcelain --untracked-files=all | grep -q ".kiro/runs/TASK-20260912-01/01/claim.md" \
    || { echo "FAIL: claim.md não visível no git do worktree"; exit 1; }
echo "   OK"

echo "A2) repo principal não recebe .kiro/runs indevida"
[[ ! -e "${MAIN}/.kiro/runs" ]] || { echo "FAIL: sujeira .kiro/runs no repo principal"; exit 1; }
echo "   OK"

echo "A3) nota do slot referencia task_id/run_seq"
note_path="${WT2}/.agent-guard/tasks/kimi2.md"
[[ "$(_task_get_field "${note_path}" "task_id")" == "TASK-20260912-01" ]] || { echo "FAIL note task_id"; exit 1; }
[[ "$(_task_get_field "${note_path}" "run_seq")" == "01" ]] || { echo "FAIL note run_seq"; exit 1; }
echo "   OK"

# ---------------------------------------------------------------------------
# C. concorrência: exatamente uma vence
# ---------------------------------------------------------------------------

echo "C1) duas claims simultâneas => exatamente uma vence"
# limpa o claim do setup para disputa limpa
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" --release "TASK-20260912-01" >/dev/null
rc2=0; rc3=0
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-01" --branch ia-kimi2/x >/dev/null 2>&1 & pid2=$!
run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" "TASK-20260912-01" --branch ia-kimi3/x >/dev/null 2>&1 & pid3=$!
wait "${pid2}" || rc2=$?
wait "${pid3}" || rc3=$?
total_rc=$(( rc2 == 0 ? 1 : 0 )); total_rc=$(( total_rc + (rc3 == 0 ? 1 : 0) ))
[[ "${total_rc}" -eq 1 ]] || { echo "FAIL: vencedores=${total_rc} (rc2=${rc2} rc3=${rc3})"; exit 1; }
lock_dir="${SESS}/claims/TASK-20260912-01.d"
lock_count="$(find "${lock_dir}" -maxdepth 1 -name '*.lock' | wc -l)"
[[ "${lock_count}" -eq 1 ]] || { echo "FAIL: ${lock_count} locks ativos (esperado 1)"; exit 1; }
active_seq="$(basename "$(find "${lock_dir}" -maxdepth 1 -name '*.lock' | head -n1)" .lock)"
# claim.md ativo = run dir SEM .released (runs históricos released não contam)
claim_md_count=0
for wt in "${WT2}" "${WT3}"; do
    runs_dir="${wt}/.kiro/runs/TASK-20260912-01"
    [[ -d "${runs_dir}" ]] || continue
    for rd in "${runs_dir}"/*/; do
        [[ -f "${rd}/claim.md" && ! -f "${rd}/.released" ]] && claim_md_count=$((claim_md_count + 1))
    done
done
[[ "${claim_md_count}" -eq 1 ]] || { echo "FAIL: ${claim_md_count} claim.md ativos (esperado 1)"; exit 1; }
echo "   OK (vencedor rc2=${rc2} rc3=${rc3})"

# ---------------------------------------------------------------------------
# D. release limpa a nota; release antigo não limpa claim nova
# ---------------------------------------------------------------------------

echo "D1) --status mostra o vencedor; release limpa nota e status"
output="$(cd "${WT2}"; AGENT_GUARD_CLAIM_IDENTITY=kimi2 AGENT_GUARD_CLAIM_SESSION_DIR=${SESS} AGENT_GUARD_REPO_ROOT=${MAIN} bash -c 'source "'"${CLAIM_SH}"'"; _claim_cli_main --status TASK-20260912-01')"
[[ "${output}" == *"CLAIMED by"* ]] || { echo "FAIL status: ${output}"; exit 1; }
winner_wt="${WT2}"; winner_id="kimi2"
if [[ "${rc3}" -eq 0 ]]; then winner_wt="${WT3}"; winner_id="kimi3"; fi
run_claim "${winner_wt}" "${winner_id}" "${SESS}" "${MAIN}" --release "TASK-20260912-01" >/dev/null
output="$(cd "${winner_wt}"; AGENT_GUARD_CLAIM_IDENTITY=${winner_id} AGENT_GUARD_CLAIM_SESSION_DIR=${SESS} AGENT_GUARD_REPO_ROOT=${MAIN} bash -c 'source "'"${CLAIM_SH}"'"; _claim_cli_main --status TASK-20260912-01')"
[[ "${output}" == *"UNCLAIMED"* ]] || { echo "FAIL pós-release: ${output}"; exit 1; }
note_winner="${winner_wt}/.agent-guard/tasks/${winner_id}.md"
[[ -z "$(_task_get_field "${note_winner}" "task_id" 2>/dev/null || true)" ]] \
    || { echo "FAIL: nota ainda anuncia task_id após release"; exit 1; }
[[ -z "$(_task_get_field "${note_winner}" "run_seq" 2>/dev/null || true)" ]] \
    || { echo "FAIL: nota ainda anuncia run_seq após release"; exit 1; }
echo "   OK"

echo "D2) release com run_seq antigo não limpa claim nova"
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-01" --branch ia-kimi2/y >/dev/null
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" --release "TASK-20260912-01" --run-seq 99 >/dev/null 2>&1 \
    && { echo "FAIL: release --run-seq inexistente deveria falhar"; exit 1; }
note_path="${WT2}/.agent-guard/tasks/kimi2.md"
[[ "$(_task_get_field "${note_path}" "task_id")" == "TASK-20260912-01" ]] \
    || { echo "FAIL: nota foi limpa por release antigo/errado"; exit 1; }
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" --release "TASK-20260912-01" >/dev/null
echo "   OK"

# ---------------------------------------------------------------------------
# E. corrupção: dois active => FAIL CLOSED
# ---------------------------------------------------------------------------

echo "E1) dois locks ativos => CORRUPT"
mkdir -p "${SESS}/claims/TASK-20260912-01.d"
printf 'slot=kimi2\nworktree=%s\n' "${WT2}" > "${SESS}/claims/TASK-20260912-01.d/01.lock"
printf 'slot=kimi3\nworktree=%s\n' "${WT3}" > "${SESS}/claims/TASK-20260912-01.d/02.lock"
output="$(cd "${WT2}"; AGENT_GUARD_CLAIM_IDENTITY=kimi2 AGENT_GUARD_CLAIM_SESSION_DIR=${SESS} AGENT_GUARD_REPO_ROOT=${MAIN} bash -c 'source "'"${CLAIM_SH}"'"; _claim_cli_main --status TASK-20260912-01' 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: --status corrupto deveria falhar"; exit 1; }
[[ "${output}" == *"CORRUPT"* ]] || { echo "FAIL: msg=${output}"; exit 1; }
if run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-01" >/dev/null 2>&1; then
    echo "FAIL: claim com 2 active passou"; exit 1
fi
rm -f "${SESS}/claims/TASK-20260912-01.d"/*.lock
echo "   OK"

echo "E2) lock com slot vazio => CORRUPT"
printf 'worktree=%s\n' "${WT2}" > "${SESS}/claims/TASK-20260912-01.d/01.lock"
if run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-01" >/dev/null 2>&1; then
    echo "FAIL: claim com lock sem slot passou"; exit 1
fi
rm -f "${SESS}/claims/TASK-20260912-01.d"/*.lock
echo "   OK"

# ---------------------------------------------------------------------------
# F. shopt nullglob preservado em todas as rotas
# ---------------------------------------------------------------------------

echo "F1) nullglob idêntico antes/depois (sucesso, erro e corrupt)"
before="$(shopt -p nullglob || true)"
(cd "${WT2}"; AGENT_GUARD_CLAIM_IDENTITY=kimi2 AGENT_GUARD_CLAIM_SESSION_DIR=${SESS} AGENT_GUARD_REPO_ROOT=${MAIN} bash -c '
    source "'"${CLAIM_SH}"'"
    _claim_cli_main --check TASK-20260912-TRIVIAL >/dev/null 2>&1
    _claim_cli_main --status TASK-INEXISTENTE >/dev/null 2>&1 || true
    _claim_cli_main --status TASK-20260912-01 >/dev/null 2>&1 || true
    shopt -p nullglob || true
') > /tmp/nullglob-after.$$ 2>/dev/null
after="$(cat /tmp/nullglob-after.$$ | tail -n1)"; rm -f /tmp/nullglob-after.$$
[[ "${before}" == "${after}" ]] || { echo "FAIL: nullglob '${before}' -> '${after}'"; exit 1; }
echo "   OK (${before})"

# ---------------------------------------------------------------------------
# G. metadata round-trip
# ---------------------------------------------------------------------------

echo "G1) parser -> update -> writer preserva todos os campos S2"
roundtrip_note="${TMP_DIR}/roundtrip.md"
meta='{"state":"coding","topic":"t","task_id":"TASK-X","run_seq":"03","slot":"kimi2","claimed_at":"2026-01-01T00:00:00","confidence":"alta","owner":"kimi2","objective":"obj","risk_class":"low","base_ref":"abc123","next_step":"n"}'
_task_write_note "${roundtrip_note}" "${meta}" "corpo"
json="$(_task_read_frontmatter "${roundtrip_note}")"
updated="$(_task_update_metadata "${json}" "next_step" "n2")"
_task_write_note "${roundtrip_note}" "${updated}" "corpo"
for field in task_id run_seq slot claimed_at confidence owner objective risk_class base_ref state topic; do
    v="$(_task_get_field "${roundtrip_note}" "${field}")"
    [[ -n "${v}" ]] || { echo "FAIL: campo ${field} perdido no round-trip"; exit 1; }
done
[[ "$(_task_get_field "${roundtrip_note}" "task_id")" == "TASK-X" ]] || { echo "FAIL rt task_id"; exit 1; }
[[ "$(_task_get_field "${roundtrip_note}" "confidence")" == "alta" ]] || { echo "FAIL rt confidence"; exit 1; }
[[ "$(_task_get_field "${roundtrip_note}" "risk_class")" == "low" ]] || { echo "FAIL rt risk_class"; exit 1; }
[[ "$(_task_get_field "${roundtrip_note}" "next_step")" == "n2" ]] || { echo "FAIL rt update"; exit 1; }
echo "   OK"

# ---------------------------------------------------------------------------
# Restante do comportamento S2
# ---------------------------------------------------------------------------

echo "H1) --check trivial passa sem claim"
output="$(cd "${WT2}"; AGENT_GUARD_CLAIM_IDENTITY=kimi2 AGENT_GUARD_CLAIM_SESSION_DIR=${SESS} AGENT_GUARD_REPO_ROOT=${MAIN} bash -c 'source "'"${CLAIM_SH}"'"; _claim_cli_main --check TASK-20260912-TRIVIAL')"
[[ "${output}" == *"trivial"* ]] || { echo "FAIL: ${output}"; exit 1; }
echo "   OK"

echo "H2) --check não-trivial exige claim do próprio slot"
output="$(cd "${WT2}"; AGENT_GUARD_CLAIM_IDENTITY=kimi2 AGENT_GUARD_CLAIM_SESSION_DIR=${SESS} AGENT_GUARD_REPO_ROOT=${MAIN} bash -c 'source "'"${CLAIM_SH}"'"; _claim_cli_main --check TASK-20260912-01' 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: check deveria exigir claim"; exit 1; }
[[ "${output}" == *"sem claim ativo"* ]] || { echo "FAIL msg: ${output}"; exit 1; }
echo "   OK"

echo "H3) TASK inexistente = fail-closed"
if run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-NOPE" >/dev/null 2>&1; then
    echo "FAIL"; exit 1
fi
echo "   OK"

echo "H4) base_ref que não resolve = fail-closed"
make_task "${WT2}" "TASK-20260912-BAD" "low" "deadbeefcafe0000000000000000000000000000"
if run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-BAD" >/dev/null 2>&1; then
    echo "FAIL"; exit 1
fi
echo "   OK"

# ---------------------------------------------------------------------------
# H5 (fix 2). --check revalida a lease ATUAL (não basta lock/identity/worktree)
# ---------------------------------------------------------------------------

echo "H5) --check OK revalida lease: released => FAIL"
make_task "${WT2}" "TASK-20260912-CHK" "low"
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-CHK" --branch ia-kimi2/chk >/dev/null
output="$(cd "${WT2}"; AGENT_GUARD_CLAIM_IDENTITY=kimi2 AGENT_GUARD_CLAIM_SESSION_DIR=${SESS} AGENT_GUARD_REPO_ROOT=${MAIN} bash -c 'source "'"${CLAIM_SH}"'"; _claim_cli_main --check TASK-20260912-CHK' 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -eq 0 && "${output}" == *"claim OK"* ]] \
    || { echo "FAIL: --check com lease ativa deveria PASS (rc=${rc}: ${output})"; exit 1; }
# lease vira released: --check precisa FAIL (sem remover lock)
make_lease "${SESS}" "kimi2" "${WT2}" "released"
output="$(cd "${WT2}"; AGENT_GUARD_CLAIM_IDENTITY=kimi2 AGENT_GUARD_CLAIM_SESSION_DIR=${SESS} AGENT_GUARD_REPO_ROOT=${MAIN} bash -c 'source "'"${CLAIM_SH}"'"; _claim_cli_main --check TASK-20260912-CHK' 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -ne 0 ]] || { echo "FAIL: --check com lease released passou"; exit 1; }
[[ "${output}" != *"claim OK"* ]] || { echo "FAIL: --check released emitiu OK"; exit 1; }
# lock continuou intocado (nenhuma remoção silenciosa)
[[ -n "$(find "${SESS}/claims/TASK-20260912-CHK.d" -maxdepth 1 -name '*.lock' 2>/dev/null)" ]] \
    || { echo "FAIL: --check removeu o lock silenciosamente"; exit 1; }
make_lease "${SESS}" "kimi2" "${WT2}"
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" --release "TASK-20260912-CHK" >/dev/null
echo "   OK"

# ---------------------------------------------------------------------------
# H6 (fix 3). --run-seq divergente NÃO deixa lock fantasma
# ---------------------------------------------------------------------------

echo "H6) --run-seq divergente falha sem lock fantasma; TASK segue claimable"
make_task "${WT2}" "TASK-20260912-SEQ" "low"
make_task "${WT3}" "TASK-20260912-SEQ" "low"
if run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-SEQ" --run-seq 99 >/dev/null 2>&1; then
    echo "FAIL: claim --run-seq 99 divergente passou"; exit 1
fi
lock_count="$(find "${SESS}/claims/TASK-20260912-SEQ.d" -maxdepth 1 -name '*.lock' 2>/dev/null | wc -l)"
[[ "${lock_count}" -eq 0 ]] || { echo "FAIL: lock fantasma (${lock_count})"; exit 1; }
# seq divergente não queimou número: outro slot pega 01 imediatamente
run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" "TASK-20260912-SEQ" >/dev/null
[[ -f "${WT3}/.kiro/runs/TASK-20260912-SEQ/01/claim.md" ]] \
    || { echo "FAIL: claim do kimi3 não gerou run 01"; exit 1; }
run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" --release "TASK-20260912-SEQ" >/dev/null
echo "   OK"

# ---------------------------------------------------------------------------
# H7 (fix 4a). run_seq GLOBAL por TASK entre worktrees
# ---------------------------------------------------------------------------

echo "H7) kimi3 nunca reutiliza run 01 já atribuído (merge pendente)"
make_task "${WT2}" "TASK-20260912-GLO" "low"
make_task "${WT3}" "TASK-20260912-GLO" "low"
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-GLO" --branch ia-kimi2/glo >/dev/null
[[ -f "${WT2}/.kiro/runs/TASK-20260912-GLO/01/claim.md" ]] || { echo "FAIL: kimi2 não gerou run 01"; exit 1; }
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" --release "TASK-20260912-GLO" >/dev/null
# kimi3 no outro worktree (sem merge do run 01) — precisa receber 02, nunca 01
run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" "TASK-20260912-GLO" --branch ia-kimi3/glo >/dev/null
[[ -f "${WT3}/.kiro/runs/TASK-20260912-GLO/02/claim.md" ]] \
    || { echo "FAIL: kimi3 deveria receber run 02"; exit 1; }
[[ ! -e "${WT3}/.kiro/runs/TASK-20260912-GLO/01" ]] \
    || { echo "FAIL: kimi3 reutilizou run 01"; exit 1; }
[[ -f "${SESS}/claims/TASK-20260912-GLO.d/02.lock" ]] \
    || { echo "FAIL: lock 02 ausente"; exit 1; }
echo "   OK"

# ---------------------------------------------------------------------------
# H8 (fix 4b). reclaim do mesmo slot: trilha durável inequívoca (superseded)
# ---------------------------------------------------------------------------

echo "H8) reclaim marca run anterior como superseded — 1 run ativo em Git"
run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" "TASK-20260912-GLO" --branch ia-kimi3/glo2 >/dev/null
[[ -f "${WT3}/.kiro/runs/TASK-20260912-GLO/03/claim.md" ]] || { echo "FAIL: run 03 não foi criado"; exit 1; }
run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" "TASK-20260912-GLO" --branch ia-kimi3/glo3 >/dev/null
prev_released="${WT3}/.kiro/runs/TASK-20260912-GLO/03/.released"
[[ -f "${prev_released}" ]] || { echo "FAIL: run 03 sem .released após reclaim"; exit 1; }
grep -q "superseded" "${prev_released}" || { echo "FAIL: .released sem razão superseded"; exit 1; }
[[ -f "${WT3}/.kiro/runs/TASK-20260912-GLO/04/claim.md" ]] \
    || { echo "FAIL: run 04 não foi criado no reclaim"; exit 1; }
[[ ! -f "${WT3}/.kiro/runs/TASK-20260912-GLO/04/.released" ]] \
    || { echo "FAIL: run corrente (04) já nasceu released"; exit 1; }
# registro transitório: seqs 01..04 atribuídos, nunca reutilizados
reg="${SESS}/claims/TASK-20260912-GLO.d/.seq-registry"
[[ -f "${reg}" ]] || { echo "FAIL: .seq-registry ausente"; exit 1; }
for expected_seq in 01 02 03 04; do
    grep -qx "${expected_seq}" "${reg}" || { echo "FAIL: seq ${expected_seq} não registrado"; exit 1; }
done
# exatamente um claim.md ativo (sem .released) para a TASK nos worktrees
active_count=0
for wt in "${WT2}" "${WT3}"; do
    for rd in "${wt}/.kiro/runs/TASK-20260912-GLO"/*/; do
        [[ -f "${rd}/claim.md" && ! -f "${rd}/.released" ]] && active_count=$((active_count + 1))
    done
done
[[ "${active_count}" -eq 1 ]] || { echo "FAIL: ${active_count} runs ativos (esperado 1)"; exit 1; }
run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" --release "TASK-20260912-GLO" >/dev/null
echo "   OK"

# I1 (revisão Amazon Q). claim/release sourced NÃO altera variável 'updated'
# preexistente do caller (release usava 'updated' sem local — vazava porque
# claim.sh é sourced no shell do operador).
echo "I1) claim+release sourced preserva 'updated' do caller"
make_task "${WT2}" "TASK-20260912-UPD" "low"
make_lease "${SESS}" "kimi2" "${WT2}"
(
    cd "${WT2}"
    export AGENT_GUARD_CLAIM_IDENTITY="kimi2"
    export AGENT_GUARD_CLAIM_SESSION_DIR="${SESS}"
    export AGENT_GUARD_REPO_ROOT="${MAIN}"
    updated="VALOR_PREEXISTENTE_DO_CALLER"
    # shellcheck source=/dev/null
    source "${CLAIM_SH}"
    _claim_cli_main "TASK-20260912-UPD" --branch ia-kimi2/upd >/dev/null
    _claim_cli_main --release "TASK-20260912-UPD" >/dev/null
    if [[ "${updated}" != "VALOR_PREEXISTENTE_DO_CALLER" ]]; then
        echo "FAIL: 'updated' do caller foi sobrescrito pelo release" >&2
        exit 1
    fi
)
echo "   OK"

# I2 (revisão independente, stale-take). Lease migrada de worktree: lock
# antigo vira STALE — holder válido exige status active E worktree_path ==
# worktree registrado no lock. Representação DURÁVEL: o tomador registra
# stale-supersedes no PRÓPRIO run dir (isolamento: zero escrita no worktree
# alheio); reconstrução por Git identifica exatamente 1 claimant ativo.
echo "I2) lease ativa em WT-B não sustenta lock antigo em WT-A (stale-take 1x, durável)"
make_task "${WT2}" "TASK-20260912-STALEWT" "low"
make_task "${WT3}" "TASK-20260912-STALEWT" "low"
make_lease "${SESS}" "kimi2" "${WT2}"
make_lease "${SESS}" "kimi3" "${WT3}"
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-STALEWT" --branch ia-kimi2/sw1 >/dev/null
[[ -f "${WT2}/.kiro/runs/TASK-20260912-STALEWT/01/claim.md" ]] || { echo "FAIL: run 01 não criado"; exit 1; }
# snapshot do run alheio: stale-take NÃO pode mutar o worktree do holder morto
run01_dir="${WT2}/.kiro/runs/TASK-20260912-STALEWT/01"
run01_listing_before="$(cd "${run01_dir}" && find . -type f | sort)"
# controle positivo: holder vivo (active + mesmo worktree) BLOQUEIA outro slot
if run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" "TASK-20260912-STALEWT" --branch ia-kimi3/sw1 >/dev/null 2>&1; then
    echo "FAIL: claim de kimi3 deveria ter sido bloqueado (holder vivo em WT-A)"; exit 1
fi
# lease do kimi2 migra para WT-B (mesmo slot, worktree_path divergente do lock)
make_lease "${SESS}" "kimi2" "${WT3}"
run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" "TASK-20260912-STALEWT" --branch ia-kimi3/sw2 >/dev/null
[[ -f "${WT3}/.kiro/runs/TASK-20260912-STALEWT/02/claim.md" ]] || { echo "FAIL: stale-take não gerou run 02"; exit 1; }
stale_dir="${SESS}/claims/TASK-20260912-STALEWT.d"
found_stale=0
for f in "${stale_dir}"/01.lock.stale.*; do
    [[ -f "${f}" ]] && found_stale=1
done
[[ "${found_stale}" -eq 1 ]] || { echo "FAIL: lock antigo não renomeado como .stale"; exit 1; }
# representação durável: stale-supersedes no run do TOMADOR, com identidade
# completa do run encerrado
marker="${WT3}/.kiro/runs/TASK-20260912-STALEWT/02/stale-supersedes"
[[ -f "${marker}" ]] || { echo "FAIL: stale-supersedes ausente no run 02"; exit 1; }
grep -q "superseded_run: 01" "${marker}" || { echo "FAIL: marker sem superseded_run"; exit 1; }
grep -q "superseded_slot: kimi2" "${marker}" || { echo "FAIL: marker sem superseded_slot"; exit 1; }
grep -q "superseded_worktree: ${WT2}" "${marker}" || { echo "FAIL: marker sem superseded_worktree"; exit 1; }
# isolamento: run alheio INTACTO (nenhuma mutação proibida em WT-A)
run01_listing_after="$(cd "${run01_dir}" && find . -type f | sort)"
[[ "${run01_listing_before}" == "${run01_listing_after}" ]] \
    || { echo "FAIL: stale-take mutou o run dir alheio"; exit 1; }
[[ ! -f "${run01_dir}/.released" ]] || { echo "FAIL: .released indevido no worktree alheio"; exit 1; }
# reconstrução usando APENAS estado durável (run dirs/Git; zero lock/journal)
read -r dcount dclaim < <(durable_state "TASK-20260912-STALEWT" "${WT2}" "${WT3}")
[[ "${dcount}" -eq 1 ]] || { echo "FAIL: reconstrução durável achou ${dcount} ativos"; exit 1; }
[[ "${dclaim}" == "wt-kimi3/02" ]] \
    || { echo "FAIL: claimant durável = ${dclaim} (esperado wt-kimi3/02)"; exit 1; }
# exatamente uma vez: agora o holder é kimi3 (active + worktree match) —
# nem mesmo o kimi2 com lease ativa assume de novo
if run_claim "${WT3}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-STALEWT" --branch ia-kimi2/sw2 >/dev/null 2>&1; then
    echo "FAIL: segundo stale-take indevido — holder kimi3 está vivo"; exit 1
fi
[[ -f "${WT3}/.kiro/runs/TASK-20260912-STALEWT/03/claim.md" ]] && { echo "FAIL: run 03 indevido após bloqueio"; exit 1; }
run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" --release "TASK-20260912-STALEWT" >/dev/null
echo "   OK"

# I3 (revisão independente). Mesmo slot com worktree migrado = STALE: o
# reclaim NÃO pode escrever .released no worktree antigo (isolamento).
echo "I3) mesmo slot + lease migrada: reclaim vira stale-take durável, WT antigo intacto"
git -C "${MAIN}" worktree add -q "${TMP_DIR}/wt-kimi2b" -b ia-kimi2/ia-a/claim-test-b 2>/dev/null
WT2B="${TMP_DIR}/wt-kimi2b"
git -C "${WT2B}" config user.email "agent-kimi2@example.com"
make_task "${WT2}" "TASK-20260912-MIGR" "low"
make_task "${WT2B}" "TASK-20260912-MIGR" "low"
make_lease "${SESS}" "kimi2" "${WT2}"
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-MIGR" --branch ia-kimi2/m1 >/dev/null
[[ -f "${WT2}/.kiro/runs/TASK-20260912-MIGR/01/claim.md" ]] || { echo "FAIL: I3 run 01 não criado"; exit 1; }
mig_run01="${WT2}/.kiro/runs/TASK-20260912-MIGR/01"
mig_listing_before="$(cd "${mig_run01}" && find . -type f | sort)"
# lease do MESMO slot migra para WT-B
make_lease "${SESS}" "kimi2" "${WT2B}"
run_claim "${WT2B}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-MIGR" --branch ia-kimi2/m2 >/dev/null
[[ -f "${WT2B}/.kiro/runs/TASK-20260912-MIGR/02/claim.md" ]] || { echo "FAIL: I3 reclaim migrado não gerou run 02"; exit 1; }
marker3="${WT2B}/.kiro/runs/TASK-20260912-MIGR/02/stale-supersedes"
[[ -f "${marker3}" ]] || { echo "FAIL: I3 stale-supersedes ausente no run 02"; exit 1; }
grep -q "superseded_run: 01" "${marker3}" || { echo "FAIL: I3 marker sem superseded_run"; exit 1; }
grep -q "superseded_worktree: ${WT2}" "${marker3}" || { echo "FAIL: I3 marker sem worktree antigo"; exit 1; }
# isolamento: run antigo byte-intact, SEM .released
mig_listing_after="$(cd "${mig_run01}" && find . -type f | sort)"
[[ "${mig_listing_before}" == "${mig_listing_after}" ]] || { echo "FAIL: I3 mutou run alheio"; exit 1; }
[[ ! -f "${mig_run01}/.released" ]] || { echo "FAIL: I3 .released indevido no WT antigo"; exit 1; }
read -r dcount3 dclaim3 < <(durable_state "TASK-20260912-MIGR" "${WT2}" "${WT2B}")
[[ "${dcount3}" -eq 1 && "${dclaim3}" == "wt-kimi2b/02" ]] \
    || { echo "FAIL: I3 reconstrução = ${dcount3} ${dclaim3}"; exit 1; }
run_claim "${WT2B}" "kimi2" "${SESS}" "${MAIN}" --release "TASK-20260912-MIGR" >/dev/null
echo "   OK"

# I4 (revisão independente). Falha pós-detecção de stale, antes da conclusão:
# --plan-file inexistente após stale detectado => invariante A — nada é
# publicado; o run antigo continua o único claim durável.
echo "I4) falha após stale detection (--plan-file inexistente) não publica intermediário"
make_task "${WT2}" "TASK-20260912-ATOMIC" "low"
make_task "${WT3}" "TASK-20260912-ATOMIC" "low"
make_lease "${SESS}" "kimi2" "${WT2}"
make_lease "${SESS}" "kimi3" "${WT3}"
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" "TASK-20260912-ATOMIC" --branch ia-kimi2/at1 >/dev/null
at_run01="${WT2}/.kiro/runs/TASK-20260912-ATOMIC/01"
at_listing_before="$(cd "${at_run01}" && find . -type f | sort)"
# lease migra; kimi3 tenta takeover com plan-file inexistente
make_lease "${SESS}" "kimi2" "${WT3}"
if run_claim "${WT3}" "kimi3" "${SESS}" "${MAIN}" "TASK-20260912-ATOMIC" --branch ia-kimi3/at2 --plan-file "${TMP_DIR}/nao-existe.md" >/dev/null 2>&1; then
    echo "FAIL: I4 claim com plan-file inexistente deveria falhar"; exit 1
fi
# invariante A: lock antigo intacto (não renomeado), sem run02, sem marker,
# worktree alheio intacto, exatamente 1 ativo = run01
at_locks="${SESS}/claims/TASK-20260912-ATOMIC.d"
[[ -f "${at_locks}/01.lock" ]] || { echo "FAIL: I4 lock original foi alterado"; exit 1; }
found_stale4=0
for f in "${at_locks}"/01.lock.stale.*; do [[ -f "${f}" ]] && found_stale4=1; done
[[ "${found_stale4}" -eq 0 ]] || { echo "FAIL: I4 publicou lock .stale em falha"; exit 1; }
[[ ! -e "${WT3}/.kiro/runs/TASK-20260912-ATOMIC/02" ]] || { echo "FAIL: I4 run02 parcial publicado"; exit 1; }
at_listing_after="$(cd "${at_run01}" && find . -type f | sort)"
[[ "${at_listing_before}" == "${at_listing_after}" ]] || { echo "FAIL: I4 mutou run alheio"; exit 1; }
read -r dcount4 dclaim4 < <(durable_state "TASK-20260912-ATOMIC" "${WT2}" "${WT3}")
[[ "${dcount4}" -eq 1 && "${dclaim4}" == "wt-kimi2/01" ]] \
    || { echo "FAIL: I4 reconstrução = ${dcount4} ${dclaim4}"; exit 1; }
run_claim "${WT2}" "kimi2" "${SESS}" "${MAIN}" --release "TASK-20260912-ATOMIC" >/dev/null
echo "   OK"

echo "ALL CLAIM V2 TESTS PASSED"
