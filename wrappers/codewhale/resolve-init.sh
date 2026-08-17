#!/usr/bin/env bash
#
# CodeWhale wrapper helper — resolve the most up-to-date agent-guard init
# script available in the ecosystem.
#
# This avoids sourcing a stale .hmvip-agent-init bundled inside a worktree
# that is parked on an old task branch. The resolution mirrors the logic in
# .kiro/shell/hmvip.sh so the wrapper and the shell helper always agree.
#
# The caller must set the following variables before sourcing this helper:
#   _AG_MAIN_REPO       — absolute path to the main repository
#   _AG_BASE_DIR        — parent directory of the worktrees
#   _AG_INIT_SCRIPT_NAME — filename of the init stub (e.g. .hmvip-agent-init)
#   _AG_REPO_ROOT       — repository from which the config was loaded
#

_ag_resolve_init_script() {
    local init_name="${_AG_INIT_SCRIPT_NAME:-.agent-guard-init}"

    # Prefer the main repo when it is on a trunk branch.
    local main_branch
    main_branch="$(git -C "${_AG_MAIN_REPO}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "${main_branch}" == "develop" || "${main_branch}" == "main" ]]; then
        if [[ -f "${_AG_MAIN_REPO}/${init_name}" ]]; then
            echo "${_AG_MAIN_REPO}/${init_name}"
            return 0
        fi
    fi

    # Fallback 1: any worktree on develop/main.
    local wt
    for wt in "${_AG_BASE_DIR}"/hmvip-ia-*; do
        [[ -d "${wt}" ]] || continue
        local wt_branch
        wt_branch="$(git -C "${wt}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        if [[ "${wt_branch}" == "develop" || "${wt_branch}" == "main" ]]; then
            if [[ -f "${wt}/${init_name}" ]]; then
                echo "${wt}/${init_name}"
                return 0
            fi
        fi
    done

    # Fallback 2: worktree whose agent-guard-core package was modified most recently.
    local best_wt=""
    local best_ts=0
    for wt in "${_AG_BASE_DIR}"/hmvip-ia-*; do
        [[ -d "${wt}" ]] || continue
        [[ -f "${wt}/${init_name}" ]] || continue
        local ts
        ts="$(git -C "${wt}" log -1 --format=%ct -- packages/agent-guard-core 2>/dev/null || echo 0)"
        if [[ "${ts}" =~ ^[0-9]+$ && "${ts}" -gt "${best_ts}" ]]; then
            best_ts="${ts}"
            best_wt="${wt}"
        fi
    done
    if [[ -n "${best_wt}" && -f "${best_wt}/${init_name}" ]]; then
        echo "${best_wt}/${init_name}"
        return 0
    fi

    # Last resort: the init from the repository we loaded the config from.
    echo "${_AG_REPO_ROOT}/${init_name}"
}
