#!/usr/bin/env bash
#
# Agent Guard — Kimi CLI Wrapper
#
# Mandatory agent isolation enforcement for the Kimi Code CLI.
# Every invocation of `kimi` inside an Agent Guard managed repository is
# routed through here, ensuring that:
#
#   1. No agent works directly in the main repository.
#   2. No agent reuses another agent's worktree.
#   3. A valid agent-guard lease is acquired before any work.
#   4. Dirty foreign work is detected and blocked at session start.
#
# The wrapper reads its configuration from agent-guard.yaml (SSOT) in the
# repository it is invoked from. Project-specific paths are no longer hardcoded.
#
# Installation:
#   mv <bin_dir>/kimi <bin_dir>/kimi.real
#   cp <path-to>/wrappers/kimi/wrapper.sh <bin_dir>/kimi
#   chmod +x <bin_dir>/kimi
#
# Emergency bypass (use only for debugging/recovery):
#   AG_WRAPPER_BYPASS=1 kimi ...
#   AG_WRAPPER_BYPASS=1 kimi ...  # legacy alias
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Emergency bypass (canonical env var + legacy alias)
# ---------------------------------------------------------------------------
if [[ "${AG_WRAPPER_BYPASS:-}" == "1" || "${AG_WRAPPER_BYPASS:-}" == "1" ]]; then
    # REAL_KIMI is resolved later; bypass is handled after config load.
    # We need it now, so perform a minimal resolution.
    _AG_REAL_KIMI="${AG_KIMI_REAL:-${AG_KIMI_REAL:-}}"
    if [[ -z "${_AG_REAL_KIMI}" ]]; then
        # Try common locations.
        _AG_REAL_KIMI_CANDIDATES=("${HOME}/.kimi-code/bin/kimi.real" "$(command -v kimi.real 2>/dev/null || true)")
        for candidate in "${_AG_REAL_KIMI_CANDIDATES[@]}"; do
            if [[ -n "${candidate}" && -x "${candidate}" ]]; then
                _AG_REAL_KIMI="${candidate}"
                break
            fi
        done
    fi
    if [[ -z "${_AG_REAL_KIMI}" || ! -x "${_AG_REAL_KIMI}" ]]; then
        echo "❌ AG WRAPPER: cannot locate real kimi binary for bypass." >&2
        exit 1
    fi
    exec "${_AG_REAL_KIMI}" "$@"
fi

# ---------------------------------------------------------------------------
# 1. Resolve current working directory
# ---------------------------------------------------------------------------
CWD="$(pwd -P 2>/dev/null || pwd)"

# Pin the lease anchor PID to this wrapper process: the init script is
# sourced below (non-interactive shell) and this same PID survives the final
# `exec` into kimi.real, so the lease stays bound to the agent process
# instead of the wrapper's parent shell (see _ag_session_pid in init.sh).
# Unset first to avoid inheriting a stale pin from a parent Agent Guard session
# (e.g. a nested `source .hmvip-agent-init` inside another leased worktree).
unset AGENT_GUARD_SESSION_PID
export AGENT_GUARD_SESSION_PID="$$"

# Resolve a usable Python interpreter cross-platform.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AG_PYTHON="$(bash "${SCRIPT_DIR}/bin/agent-guard-python" 2>/dev/null || echo "python3")"
export AG_PYTHON

# ---------------------------------------------------------------------------
# 2. Load repository configuration from agent-guard.yaml
# ---------------------------------------------------------------------------
_AG_CONFIG_LOADED="false"
_AG_REPO_ROOT=""
_AG_PACKAGE_ROOT=""
_AG_CONFIG_BIN=""
_AG_MAIN_REPO=""
_AG_BASE_DIR=""
_AG_BIN_DIR=""
_AG_REAL_BIN_NAME=""
_AG_REAL_KIMI=""
_AG_IDENTITY_VAR=""
_AG_KNOWN_IDENTITIES=""

try_source_real_kimi() {
    local bin_dir="$1"
    local real_name="$2"
    if [[ -n "${bin_dir}" && -n "${real_name}" && -x "${bin_dir}/${real_name}" ]]; then
        echo "${bin_dir}/${real_name}"
        return 0
    fi
    return 1
}

_ag_load_config() {
    local git_root
    git_root="$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "${git_root}" ]]; then
        return 1
    fi

    # The SSOT configuration file must exist. Without it we cannot determine
    # main repo, base dir, identities or wrapper paths safely.
    if [[ ! -f "${git_root}/agent-guard.yaml" ]]; then
        return 1
    fi

    local package_root
    package_root="$(bash "${git_root}/packages/agent-guard-core/bin/agent-guard-config" get paths.package_root 'packages/agent-guard-core' 2>/dev/null || echo 'packages/agent-guard-core')"
    local config_bin="${git_root}/${package_root}/bin/agent-guard-config"
    if [[ ! -f "${config_bin}" ]]; then
        return 1
    fi

    _AG_REPO_ROOT="${git_root}"
    _AG_PACKAGE_ROOT="${package_root}"
    _AG_CONFIG_BIN="${config_bin}"
    _AG_MAIN_REPO="$(bash "${config_bin}" get paths.main_repo "${git_root}" 2>/dev/null || echo "${git_root}")"
    _AG_BASE_DIR="$(bash "${config_bin}" get paths.base_dir "$(dirname "${_AG_MAIN_REPO}")" 2>/dev/null || echo "$(dirname "${_AG_MAIN_REPO}")")"
    _AG_BIN_DIR="$(bash "${config_bin}" get wrappers.kimi.bin_dir "${HOME}/.kimi-code/bin" 2>/dev/null || echo "${HOME}/.kimi-code/bin")"
    _AG_REAL_BIN_NAME="$(bash "${config_bin}" get wrappers.kimi.real_bin 'kimi.real' 2>/dev/null || echo 'kimi.real')"
    _AG_IDENTITY_VAR="$(bash "${config_bin}" get commit.identity_env_var 'AGENT_GUARD_IDENTITY' 2>/dev/null || echo 'AGENT_GUARD_IDENTITY')"
    _AG_INIT_SCRIPT_NAME="$(bash "${config_bin}" get paths.init_script '.agent-guard-init' 2>/dev/null || echo '.agent-guard-init')"
    _AG_KNOWN_IDENTITIES="$(bash "${config_bin}" keys identities 2>/dev/null || true)"

    # Resolve real kimi binary.
    if ! _AG_REAL_KIMI="$(try_source_real_kimi "${_AG_BIN_DIR}" "${_AG_REAL_BIN_NAME}")"; then
        # Fallback: search in PATH.
        local path_candidate
        path_candidate="$(command -v "${_AG_REAL_BIN_NAME}" 2>/dev/null || true)"
        if [[ -n "${path_candidate}" && -x "${path_candidate}" ]]; then
            _AG_REAL_KIMI="${path_candidate}"
        fi
    fi

    _AG_CONFIG_LOADED="true"
    return 0
}

# Heuristic: is CWD a git repository that looks like an Agent Guard main repo
# but whose config could not be loaded? This usually means the main repo is on
# a detached/neutral branch (e.g. _released/*) or is missing agent-guard.yaml.
_ag_looks_like_main_repo() {
    if ! git -C "${CWD}" rev-parse --show-toplevel >/dev/null 2>&1; then
        return 1
    fi
    # Presence of the package or init stubs strongly indicates the main repo.
    if [[ -d "${CWD}/packages/agent-guard-core" || -f "${CWD}/.agent-guard-init" || -f "${CWD}/.hmvip-agent-init" ]]; then
        return 0
    fi
    return 1
}

if ! _ag_load_config; then
    if _ag_looks_like_main_repo; then
        echo "❌❌❌ AG WRAPPER: main repository is not in a leasable state." >&2
        echo "" >&2
        echo "   The wrapper could not load agent-guard.yaml from:" >&2
        echo "     ${CWD}" >&2
        echo "" >&2
        echo "   Common causes:" >&2
        echo "     - The main repo is on a neutral branch (e.g. _released/*)." >&2
        echo "     - The main repo is outdated and missing agent-guard.yaml." >&2
        echo "     - agent-guard.yaml was deleted or renamed." >&2
        echo "" >&2
        echo "   Required actions (run as the repo owner, not as an AI agent):" >&2
        echo "     cd ${CWD}" >&2
        echo "     git checkout develop" >&2
        echo "     git pull origin develop" >&2
        echo "     # ensure agent-guard.yaml exists" >&2
        echo "" >&2
        echo "   Emergency bypass (use only for recovery):" >&2
        echo "     AG_WRAPPER_BYPASS=1 kimi ..." >&2
        exit 1
    fi

    # Not in an Agent Guard managed repository; pass through unchanged.
    # We still need a real binary. Try to find it.
    _AG_REAL_KIMI="${AG_KIMI_REAL:-${AG_KIMI_REAL:-}}"
    if [[ -z "${_AG_REAL_KIMI}" ]]; then
        for candidate in "${HOME}/.kimi-code/bin/kimi.real" "$(command -v kimi.real 2>/dev/null || true)" "$(command -v kimi 2>/dev/null || true)"; do
            if [[ -n "${candidate}" && -x "${candidate}" ]]; then
                _AG_REAL_KIMI="${candidate}"
                break
            fi
        done
    fi
    if [[ -n "${_AG_REAL_KIMI}" && -x "${_AG_REAL_KIMI}" ]]; then
        exec "${_AG_REAL_KIMI}" "$@"
    fi
    echo "❌ AG WRAPPER: cannot locate real kimi binary." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. If not inside this ecosystem, pass through unchanged
# ---------------------------------------------------------------------------
if [[ "${CWD}" != "${_AG_MAIN_REPO}"* ]]; then
    _AG_INSIDE_WORKTREE="false"
    for prefix in ${_AG_KNOWN_IDENTITIES}; do
        _AG_WT_PREFIX="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" '' 2>/dev/null || true)"
        if [[ -n "${_AG_WT_PREFIX}" && "${CWD}" == "${_AG_BASE_DIR}/${_AG_WT_PREFIX}"* ]]; then
            _AG_INSIDE_WORKTREE="true"
            break
        fi
    done
    if [[ "${_AG_INSIDE_WORKTREE}" != "true" ]]; then
        if [[ -n "${_AG_REAL_KIMI}" && -x "${_AG_REAL_KIMI}" ]]; then
            exec "${_AG_REAL_KIMI}" "$@"
        fi
        echo "❌ AG WRAPPER: cannot locate real kimi binary." >&2
        exit 1
    fi
fi

if [[ -z "${_AG_REAL_KIMI}" || ! -x "${_AG_REAL_KIMI}" ]]; then
    echo "❌ AG WRAPPER: real kimi binary not found at ${_AG_BIN_DIR}/${_AG_REAL_BIN_NAME}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Management/read-only commands do not require a lease
# ---------------------------------------------------------------------------
_ag_is_management_command() {
    for arg in "$@"; do
        case "${arg}" in
            --version|-V|--help|-h|update|upgrade|doctor|login|provider|export|migrate|acp)
                return 0
                ;;
        esac
    done
    return 1
}

if _ag_is_management_command "$@"; then
    exec "${_AG_REAL_KIMI}" "$@"
fi

# ---------------------------------------------------------------------------
# 5. Helper: check whether a lease is already active for this shell
# ---------------------------------------------------------------------------
_ag_have_lease() {
    [[ -n "${_AG_WORKTREE:-}" && -n "${_AG_IDENTITY:-}" && -n "${_AG_BRANCH:-}" ]]
}

# ---------------------------------------------------------------------------
# 6. Helper: detect if current directory is inside a foreign worktree
# ---------------------------------------------------------------------------
_ag_is_foreign_worktree() {
    local current_worktree
    current_worktree="${_AG_WORKTREE:-}"

    # If cwd is main repo, it is not a worktree path
    if [[ "${CWD}" == "${_AG_MAIN_REPO}" ]]; then
        return 1
    fi

    # If cwd is exactly our leased worktree, OK
    if [[ "${CWD}" == "${current_worktree}" ]]; then
        return 1
    fi

    # If cwd is inside another agent worktree, it is foreign
    for prefix in ${_AG_KNOWN_IDENTITIES}; do
        local wt_prefix
        wt_prefix="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" '' 2>/dev/null || true)"
        if [[ -n "${wt_prefix}" && "${CWD}" == "${_AG_BASE_DIR}/${wt_prefix}"* ]]; then
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# 7. Helper: verify leased worktree is not dirty with foreign work
# ---------------------------------------------------------------------------
_ag_check_worktree_clean() {
    local worktree="$1"
    local identity="$2"

    if [[ ! -d "${worktree}" ]]; then
        echo "❌ AG WRAPPER: leased worktree does not exist: ${worktree}" >&2
        return 1
    fi

    local status_output
    status_output="$(git -C "${worktree}" status --porcelain=v1 2>/dev/null || true)"

    if [[ -z "${status_output}" ]]; then
        return 0
    fi

    if [[ "${AG_ALLOW_DIRTY_WORKTREE:-}" != "1" && "${AG_ALLOW_DIRTY_WORKTREE:-}" != "1" ]]; then
        echo "❌ AG WRAPPER: worktree ${worktree} has uncommitted changes." >&2
        echo "   Identity: ${identity}" >&2
        echo "   Resolve before starting a new session (commit, stash, or run with AG_ALLOW_DIRTY_WORKTREE=1 for recovery)." >&2
        echo "" >&2
        echo "   git status:" >&2
        git -C "${worktree}" status --short >&2
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# 8. Acquire lease if needed
# ---------------------------------------------------------------------------
_ag_worktree_is_dirty() {
    local worktree="$1"
    local output
    output="$(git -C "${worktree}" status --porcelain=v1 2>/dev/null || true)"
    [[ -n "${output}" ]]
}

_ag_worktree_has_live_agent() {
    local worktree="$1"
    local own_pid="$$"

    # Build the set of known agent PIDs by inspecting comm/cmdline.  Processes
    # renamed via exec -a are caught by argv[0] in /proc/PID/cmdline.
    local agent_pids=""
    local pid
    for pid in /proc/[0-9]*; do
        [[ -d "${pid}" ]] || continue
        local pid_num="${pid#/proc/}"
        local comm cmdline_argv0
        comm="$(cat "${pid}/comm" 2>/dev/null || true)"
        cmdline_argv0="$(tr '\0' '\n' < "${pid}/cmdline" 2>/dev/null | head -n1 || true)"
        case "${comm}|${cmdline_argv0}" in
            *kimi-code*|*claude*|*gemini*|*grok*|*cursor*|*antigravity*|*kiro*|*kimi*)
                agent_pids="${agent_pids} ${pid_num}"
                ;;
        esac
    done

    # For every process whose cwd is the worktree, walk the ancestor chain
    # looking for a known agent.  This catches child processes such as MCP
    # servers spawned via "npm exec" or "node" whose own names do not contain
    # the agent identifier.
    for pid in /proc/[0-9]*; do
        [[ -d "${pid}" ]] || continue
        local pid_num="${pid#/proc/}"
        [[ "${pid_num}" == "${own_pid}" ]] && continue
        local cwd_link
        cwd_link="$(readlink "${pid}/cwd" 2>/dev/null || true)"
        [[ "${cwd_link}" != "${worktree}" ]] && continue

        # Collect this process's ancestor chain.
        local current_pid="${pid_num}"
        local ancestors=""
        local visited=""
        while [[ -n "${current_pid}" && "${current_pid}" != "1" ]]; do
            if [[ "${visited}" =~ (^|[[:space:]])${current_pid}([[:space:]]|$) ]]; then
                break
            fi
            visited="${visited} ${current_pid}"
            ancestors="${ancestors} ${current_pid}"
            current_pid="$(grep '^PPid:' "/proc/${current_pid}/status" 2>/dev/null | awk '{print $2}' || true)"
        done

        # Ignore our own subprocesses that happen to visit the worktree.
        if [[ "${ancestors}" =~ (^|[[:space:]])${own_pid}([[:space:]]|$) ]]; then
            continue
        fi

        # Any known agent ancestor means another session holds the worktree.
        for apid in ${agent_pids}; do
            if [[ "${ancestors}" =~ (^|[[:space:]])${apid}([[:space:]]|$) ]]; then
                return 0
            fi
        done
    done

    return 1
}

# Return the most recent resumable worktree for a given identity prefix.
# Reads the Agent Guard journal and, for the newest init/attach event whose
# identity matches ${prefix}<number>, checks whether the recorded worktree is
# available and not held by another live agent process. This enables "sticky
# sessions": restarting Kimi from the main repository returns to the last
# active worktree instead of allocating the first free slot.
_ag_find_resumable_worktree() {
    local prefix="$1"
    local journal_path
    journal_path="${_AG_MAIN_REPO}/$(bash "${_AG_CONFIG_BIN}" get journal.path ".agent-guard/journal/agent-guard.jsonl" 2>/dev/null || echo ".agent-guard/journal/agent-guard.jsonl")"
    [[ ! -f "${journal_path}" ]] && return 1

    local session_dir
    session_dir="${_AG_MAIN_REPO}/$(bash "${_AG_CONFIG_BIN}" get paths.session_storage ".agent-guard/sessions")"

    # Own PID is used to exclude the current wrapper process from the live-agent
    # scan; otherwise a resuming session would see itself as an intruder.
    local own_pid="$$"

    ${AG_PYTHON} - "${journal_path}" "${prefix}" "${session_dir}" "${own_pid}" <<'PY'
import json, sys, os, re, subprocess
journal_path, prefix, session_dir, own_pid = sys.argv[1:5]
own_pid = str(own_pid)
identity_re = re.compile(rf'^{re.escape(prefix)}\\d+$')
AGENT_NAMES = {'kimi-code', 'claude', 'gemini', 'grok', 'cursor', 'antigravity', 'kiro', 'kimi'}

def worktree_has_live_agent(worktree, own_pid):
    """Return True if an agent process (other than own_pid) holds worktree.

    Detection walks the ancestor chain of every process whose cwd is the
    worktree. This catches not only the main agent binary but also child
    processes such as MCP servers spawned via npm exec or node.
    """
    try:
        # Build the set of known agent PIDs.
        agent_pids = set()
        for entry in os.listdir('/proc'):
            if not entry.isdigit():
                continue
            names = set()
            try:
                with open(f'/proc/{entry}/comm', 'r') as f:
                    names.add(f.read().strip())
            except (OSError, FileNotFoundError):
                pass
            try:
                with open(f'/proc/{entry}/cmdline', 'rb') as f:
                    argv0 = f.read().split(b'\0', 1)[0].decode('utf-8', 'replace')
                    if argv0:
                        names.add(argv0)
            except (OSError, FileNotFoundError):
                pass
            if names & AGENT_NAMES:
                agent_pids.add(entry)

        # For every process in the worktree, collect its ancestor chain. If our
        # own PID is in the chain, it is just our own subprocess visiting the
        # worktree (e.g. a test); ignore it. Any known agent ancestor means the
        # worktree is held by another live session.
        for entry in os.listdir('/proc'):
            if not entry.isdigit() or entry == str(own_pid):
                continue
            try:
                cwd = os.readlink(f'/proc/{entry}/cwd')
            except (OSError, FileNotFoundError):
                continue
            if cwd != worktree:
                continue

            current = entry
            visited = set()
            ancestors = []
            while current and current != '1' and current not in visited:
                visited.add(current)
                ancestors.append(current)
                try:
                    with open(f'/proc/{current}/status') as f:
                        for line in f:
                            if line.startswith('PPid:'):
                                current = line.split()[1]
                                break
                        else:
                            break
                except (OSError, FileNotFoundError):
                    break

            if str(own_pid) in ancestors:
                continue
            if agent_pids.intersection(ancestors):
                return True
    except Exception:
        pass
    return False

events = []
with open(journal_path, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get('action') not in ('init', 'attach'):
            continue
        ident = e.get('identity', '')
        if not identity_re.match(ident):
            continue
        events.append(e)

# Most recent first.
events.reverse()

for e in events:
    worktree = e.get('worktree', '')
    branch = e.get('branch', '')
    identity = e.get('identity', '')

    if not worktree or not branch or not os.path.isdir(worktree):
        continue
    # Never resume a worktree parked on its neutral post-release branch.
    if branch.startswith('_released/'):
        continue
    if not os.path.isdir(os.path.join(worktree, '.git')) and \
       not os.path.isfile(os.path.join(worktree, '.git')):
        continue

    # Verify the branch still exists locally.
    try:
        with open(os.devnull, 'w') as devnull:
            rc = subprocess.call(
                ['git', '-C', worktree, 'show-ref', '--verify', '--quiet', f'refs/heads/{branch}'],
                stdout=devnull, stderr=devnull
            )
        if rc != 0:
            continue
    except Exception:
        continue

    # If a session file exists and points to a live PID, the session is still
    # held by a running process and must not be hijacked.
    session_file = os.path.join(session_dir, f'{identity}.json')
    if os.path.isfile(session_file):
        try:
            with open(session_file) as f:
                data = json.load(f)
            if data.get('status') == 'active':
                pid = data.get('pid')
                if pid and os.path.isdir(f'/proc/{pid}'):
                    continue
        except Exception:
            pass

    # Even when the session file is missing or stale, refuse to resume a
    # worktree that currently hosts another live agent process.
    if worktree_has_live_agent(worktree, own_pid):
        continue

    print(worktree)
    sys.exit(0)

sys.exit(1)
PY
}

_ag_find_free_kimi_worktree() {
    local session_dir
    session_dir="${_AG_MAIN_REPO}/$(bash "${_AG_CONFIG_BIN}" get paths.session_storage ".agent-guard/sessions")"
    for prefix in ${_AG_KNOWN_IDENTITIES}; do
        [[ "${prefix}" == "kimi" ]] || continue
        local wt_prefix
        wt_prefix="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" '' 2>/dev/null || true)"
        [[ -z "${wt_prefix}" ]] && continue

        # Respect optional dynamic slot expansion configured in agent-guard.yaml.
        local initial_slots max_slots
        initial_slots="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.slots" '1' 2>/dev/null || echo '1')"
        max_slots="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.max_slots" "${initial_slots}" 2>/dev/null || echo "${initial_slots}")"
        [[ "${max_slots}" -lt "${initial_slots}" ]] && max_slots="${initial_slots}"

        for n in $(seq 1 "${max_slots}"); do
            local identity="${prefix}${n}"
            local worktree="${_AG_BASE_DIR}/${wt_prefix}${n}"
            local session_file="${session_dir}/${identity}.json"

            # The wrapper does not create missing worktrees here; creation is
            # delegated to the init script when expansion is required.
            [[ ! -d "${worktree}" ]] && continue

            local is_free=true
            local current_branch
            current_branch="$(git -C "${worktree}" branch --show-current 2>/dev/null || true)"

            # A worktree parked on its neutral _released/<identity> branch must not
            # be selected as "free" for automatic reuse. It is in cooldown/post-release
            # state and should only be reacquired through explicit allocation.
            if [[ "${current_branch}" == "_released/${identity}" ]]; then
                is_free=false
            fi

            if [[ "${is_free}" == "true" && -f "${session_file}" ]]; then
                local status pid
                status="$(${AG_PYTHON} -c "import json,sys; d=json.load(open('${session_file}')); print(d.get('status','free'))" 2>/dev/null || echo free)"
                pid="$(${AG_PYTHON} -c "import json,sys; d=json.load(open('${session_file}')); print(d.get('pid',''))" 2>/dev/null || echo '')"
                if [[ "${status}" == "active" && -n "${pid}" && -d "/proc/${pid}" ]]; then
                    is_free=false
                fi
            fi

            if [[ "${is_free}" == "true" ]] && _ag_worktree_is_dirty "${worktree}"; then
                is_free=false
            fi

            if [[ "${is_free}" == "true" ]] && _ag_worktree_has_live_agent "${worktree}"; then
                is_free=false
            fi

            if [[ "${is_free}" == "true" ]]; then
                echo "${worktree}"
                return 0
            fi
        done
    done
    return 1
}

if ! _ag_have_lease; then
    _AG_INIT_SCRIPT="${_AG_MAIN_REPO}/${_AG_INIT_SCRIPT_NAME}"
    if [[ ! -f "${_AG_INIT_SCRIPT}" ]]; then
        echo "❌ AG WRAPPER: ${_AG_INIT_SCRIPT} not found." >&2
        exit 1
    fi

    _AG_SKIP_INIT="false"

    if [[ "${CWD}" == "${_AG_MAIN_REPO}" ]]; then
        # Try to resume the most recent active session before allocating a new slot.
        _AG_RESUMABLE_WORKTREE="$(_ag_find_resumable_worktree "kimi" 2>/dev/null || true)"
        if [[ -n "${_AG_RESUMABLE_WORKTREE}" ]]; then
            echo "🔄 AG WRAPPER: resuming last active session at ${_AG_RESUMABLE_WORKTREE}" >&2
            cd "${_AG_RESUMABLE_WORKTREE}" || exit 1
            CWD="${_AG_RESUMABLE_WORKTREE}"
        else
            _AG_FREE_WORKTREE="$(_ag_find_free_kimi_worktree 2>/dev/null || true)"
            if [[ -n "${_AG_FREE_WORKTREE}" ]]; then
                cd "${_AG_FREE_WORKTREE}" || exit 1
                CWD="${_AG_FREE_WORKTREE}"
            else
                # No existing worktree is free.  Ask the init script to allocate
                # a new slot, which will expand beyond the configured initial
                # slots when auto_expand is enabled.
                default_role="$(bash "${_AG_CONFIG_BIN}" get "wrappers.kimi.default_role" "ia-a" 2>/dev/null || echo "ia-a")"
                echo "🔄 AG WRAPPER: no free worktree available; allocating new slot..." >&2
                ORIGINAL_ARGS=("$@")
                set --
                if ! source "${_AG_INIT_SCRIPT}" kimi "${default_role}" >/tmp/ag-wrapper-lease.log 2>&1; then
                    echo "❌ AG WRAPPER: failed to acquire agent lease." >&2
                    echo "   Log: /tmp/ag-wrapper-lease.log" >&2
                    cat /tmp/ag-wrapper-lease.log >&2
                    exit 1
                fi
                set -- "${ORIGINAL_ARGS[@]}"
                CWD="$(pwd)"
                _AG_SKIP_INIT="true"
            fi
        fi
    else
        if _ag_worktree_has_live_agent "${CWD}"; then
            echo "❌ AG WRAPPER: worktree '${CWD}' already has a live agent session." >&2
            echo "   Start kimi from ${_AG_MAIN_REPO} to get a free worktree," >&2
            echo "   or explicitly attach to your branch with: source agent-guard attach <branch>" >&2
            exit 1
        fi
    fi

    if [[ "${_AG_SKIP_INIT}" != "true" ]]; then
        ORIGINAL_ARGS=("$@")
        set --
        if ! source "${_AG_INIT_SCRIPT}" >/tmp/ag-wrapper-lease.log 2>&1; then
            echo "❌ AG WRAPPER: failed to acquire agent lease." >&2
            echo "   Log: /tmp/ag-wrapper-lease.log" >&2
            cat /tmp/ag-wrapper-lease.log >&2
            exit 1
        fi
        set -- "${ORIGINAL_ARGS[@]}"
    fi

    # In reuse mode the init script exports the configured identity variable
    # (and legacy AGENT_GUARD_IDENTITY alias for older projects).
    _AG_IDENTITY_VALUE="$(eval echo "\${${_AG_IDENTITY_VAR}:-}")"
    export _AG_WORKTREE="${AG_WORKTREE_PATH:-${AGENT_GUARD_WORKTREE_PATH:-}}"
    export _AG_IDENTITY="${_AG_IDENTITY_VALUE:-${AGENT_GUARD_IDENTITY:-}}"
    export _AG_BRANCH="${AG_BRANCH:-${AGENT_GUARD_BRANCH:-}}"

    # Legacy aliases used by older Kimi CLI builds and by the Kimi Status
    # Indicator extension. Keeping them avoids regressions in consumers that
    # expect the old HMVIP-specific variable names.
    export _HMVIP_WORKTREE="${_AG_WORKTREE}"
    export _HMVIP_IDENTITY="${_AG_IDENTITY}"
    export _HMVIP_BRANCH="${_AG_BRANCH}"
fi

# ---------------------------------------------------------------------------
# 8.5 Session trace initialization (best-effort)
# ---------------------------------------------------------------------------
# Initialize a local trace directory for this worktree and record that the
# wrapper was invoked. Heartbeats are written on subsequent invocations when
# enough time has passed, so a crashed frontend still leaves a recoverable
# trail of metadata even if no explicit checkpoint was committed.
_ag_session_trace_dir="${_AG_WORKTREE}/.agent-guard/session"
_ag_session_trace_script="${_AG_REPO_ROOT}/${_AG_PACKAGE_ROOT:-packages/agent-guard-core}/src/session_trace.sh"
if [[ -f "${_ag_session_trace_script}" && -n "${_AG_WORKTREE:-}" && -n "${_AG_IDENTITY:-}" && -n "${_AG_BRANCH:-}" ]]; then
    AGENT_GUARD_REPO_ROOT="${_AG_REPO_ROOT}"
    AGENT_GUARD_WORKTREE_PATH="${_AG_WORKTREE}"
    AGENT_GUARD_IDENTITY="${_AG_IDENTITY}"
    AGENT_GUARD_BRANCH="${_AG_BRANCH}"
    AGENT_GUARD_SESSION_DIR="${_ag_session_trace_dir}"
    export AGENT_GUARD_REPO_ROOT AGENT_GUARD_WORKTREE_PATH AGENT_GUARD_IDENTITY AGENT_GUARD_BRANCH AGENT_GUARD_SESSION_DIR

    (
        source "${_ag_session_trace_script}" >/dev/null 2>&1
        _trace_init >/dev/null 2>&1 || true
        _trace_write_event "wrapper_invoke" "$(printf '{"argv":%s}' "$(printf '%s ' "$@" | ${AG_PYTHON} -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '""')" 2>/dev/null || true)" >/dev/null 2>&1 || true

        # Heartbeat if enough time elapsed since last recorded heartbeat.
        heartbeat_interval="${AGENT_GUARD_HEARTBEAT_INTERVAL_SECONDS:-300}"
        last_heartbeat=0
        if [[ -f "${_ag_session_trace_dir}/current/.last_heartbeat" ]]; then
            last_heartbeat="$(cat "${_ag_session_trace_dir}/current/.last_heartbeat" 2>/dev/null || echo 0)"
        fi
        now="$(date +%s)"
        if [[ $((now - last_heartbeat)) -ge ${heartbeat_interval} ]]; then
            _trace_heartbeat "wrapper periodic heartbeat" >/dev/null 2>&1 || true
            date +%s > "${_ag_session_trace_dir}/current/.last_heartbeat" 2>/dev/null || true
        fi
    )

    # Start a background watcher to snapshot Kimi session metadata (title,
    # lastPrompt, sessionId) while the frontend process is alive. This captures
    # conversation context even if the frontend crashes before writing an
    # explicit checkpoint. The watcher is best-effort and never blocks Kimi.
    watch_interval="${AGENT_GUARD_KIMI_WATCH_INTERVAL_SECONDS:-60}"
    if [[ "${watch_interval}" -gt 0 && -n "${_AG_WORKTREE:-}" ]]; then
        (
            source "${_ag_session_trace_script}" >/dev/null 2>&1
            _trace_watch_kimi_session "$$" "${_AG_WORKTREE}" "${_ag_session_trace_dir}" "${watch_interval}" "${AGENT_GUARD_KIMI_WATCH_CHECKPOINT_INTERVAL_SECONDS:-300}" >/dev/null 2>&1
        ) &
        disown 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# 9. Validate lease variables
# ---------------------------------------------------------------------------
if [[ -z "${_AG_WORKTREE:-}" || -z "${_AG_IDENTITY:-}" || -z "${_AG_BRANCH:-}" ]]; then
    echo "❌ AG WRAPPER: lease is incomplete. Run 'source agent-guard init' manually." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 10. Foreign worktree guard
# ---------------------------------------------------------------------------
if _ag_is_foreign_worktree; then
    echo "❌ AG WRAPPER: current directory '${CWD}' is a foreign worktree." >&2
    echo "   Your assigned worktree is: ${_AG_WORKTREE}" >&2
    echo "   Your identity is: ${_AG_IDENTITY}" >&2
    echo "   Change to your worktree or start kimi from ${_AG_MAIN_REPO}." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 11. Worktree cleanliness guard
# ---------------------------------------------------------------------------
if ! _ag_check_worktree_clean "${CWD}" "${_AG_IDENTITY}"; then
    exit 1
fi

# ---------------------------------------------------------------------------
# 12. If launched from main repo, switch to leased worktree
# ---------------------------------------------------------------------------
if [[ "${CWD}" == "${_AG_MAIN_REPO}" ]]; then
    cd "${_AG_WORKTREE}"
fi

# ---------------------------------------------------------------------------
# 13. Execute real Kimi
# ---------------------------------------------------------------------------
exec "${_AG_REAL_KIMI}" "$@"
