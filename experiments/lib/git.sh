#!/usr/bin/env bash

# Git mutation helpers. Source experiments/lib/common.sh before this file.

GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-}"
VALUES_FILE="${VALUES_FILE:-${REPO_ROOT}/helm/microservices-app/values.yaml}"
VALUES_EDITOR="${EXPERIMENTS_DIR}/lib/update_values.py"
LAST_GIT_COMMIT=""
VALUES_RELATIVE=""
ACTIVE_CHANGE_COMMIT=""
ACTIVE_ROLLBACK_COMMIT=""
GIT_CLEANUP_TRAPS_INSTALLED=false

git_options() {
  cat <<'EOF'
  --remote NAME          Git remote watched by the controller (default: origin)
  --branch NAME          Watched branch (default: current branch)
  --values-file PATH     Shared Helm values file
EOF
}

parse_git_args() {
  GIT_REMAINING_ARGS=()
  while (($#)); do
    case "$1" in
      --remote)
        (($# >= 2)) || die "--remote requires a value"
        GIT_REMOTE="$2"
        shift 2
        ;;
      --branch)
        (($# >= 2)) || die "--branch requires a value"
        GIT_BRANCH="$2"
        shift 2
        ;;
      --values-file)
        (($# >= 2)) || die "--values-file requires a value"
        VALUES_FILE="$2"
        shift 2
        ;;
      *)
        GIT_REMAINING_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

prepare_git_mutation() {
  local current_branch local_head remote_head remote_line
  [[ -f "${VALUES_FILE}" ]] || die "Values file does not exist: ${VALUES_FILE}"
  git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a Git repository"
  VALUES_FILE="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "${VALUES_FILE}")"
  VALUES_RELATIVE="$(python3 -c 'from pathlib import Path; import sys; root=Path(sys.argv[1]).resolve(); path=Path(sys.argv[2]).resolve(); print(path.relative_to(root).as_posix())' \
    "${REPO_ROOT}" "${VALUES_FILE}" 2>/dev/null)" || die "Values file must be inside the repository"
  if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=normal)" ]]; then
    die "Git worktree must be clean before a Git-changing experiment"
  fi
  git -C "${REPO_ROOT}" remote get-url "${GIT_REMOTE}" >/dev/null 2>&1 || \
    die "Git remote not found: ${GIT_REMOTE}"
  if [[ -z "${GIT_BRANCH}" ]]; then
    GIT_BRANCH="$(git -C "${REPO_ROOT}" branch --show-current)"
  fi
  [[ -n "${GIT_BRANCH}" ]] || die "Detached HEAD is not supported; pass --branch"
  git -C "${REPO_ROOT}" check-ref-format --branch "${GIT_BRANCH}" >/dev/null 2>&1 || \
    die "Invalid Git branch name: ${GIT_BRANCH}"

  current_branch="$(git -C "${REPO_ROOT}" branch --show-current)"
  [[ "${current_branch}" == "${GIT_BRANCH}" ]] || \
    die "Current branch '${current_branch:-<detached>}' does not match watched branch '${GIT_BRANCH}'"

  local_head="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  remote_line="$(git -C "${REPO_ROOT}" ls-remote --exit-code --heads \
    "${GIT_REMOTE}" "refs/heads/${GIT_BRANCH}" 2>/dev/null)" || \
    die "Cannot resolve ${GIT_REMOTE}/refs/heads/${GIT_BRANCH}; verify the remote and credentials"
  read -r remote_head _ <<<"${remote_line}"
  [[ -n "${remote_head}" ]] || \
    die "Remote branch does not exist: ${GIT_REMOTE}/refs/heads/${GIT_BRANCH}"
  [[ "${local_head}" == "${remote_head}" ]] || \
    die "Local HEAD ${local_head} differs from ${GIT_REMOTE}/${GIT_BRANCH} (${remote_head}); synchronize it before the experiment"

  install_git_cleanup_traps
}

install_git_cleanup_traps() {
  if [[ "${GIT_CLEANUP_TRAPS_INSTALLED}" == true ]]; then
    return 0
  fi
  trap 'git_cleanup_signal INT' INT
  trap 'git_cleanup_signal TERM' TERM
  trap 'git_cleanup_on_exit $?' EXIT
  GIT_CLEANUP_TRAPS_INSTALLED=true
}

git_cleanup_signal() {
  local signal_name="$1"
  local signal_status=1
  case "${signal_name}" in
    INT) signal_status=130 ;;
    TERM) signal_status=143 ;;
  esac
  log "Received SIG${signal_name}; terminating after Git baseline cleanup"
  if [[ -n "${CURRENT_START_MS}" && "${CURRENT_RESULT_RECORDED}" == false ]]; then
    finish_failure "${CURRENT_TEST_NAME:-unknown}" "${CURRENT_ITERATION:-0}" \
      "${CURRENT_DETECTION_ISO}" "interrupted"
  fi
  exit "${signal_status}"
}

arm_git_cleanup() {
  ACTIVE_CHANGE_COMMIT="$1"
  ACTIVE_ROLLBACK_COMMIT=""
  log "Registered emergency Git rollback for ${ACTIVE_CHANGE_COMMIT}"
}

disarm_git_cleanup() {
  ACTIVE_CHANGE_COMMIT=""
  ACTIVE_ROLLBACK_COMMIT=""
}

existing_rollback_for_active_change() {
  local current_head parent_head baseline_parent
  [[ -n "${ACTIVE_CHANGE_COMMIT}" ]] || return 1
  current_head="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null)" || return 1
  parent_head="$(git -C "${REPO_ROOT}" rev-parse "${current_head}^" 2>/dev/null)" || return 1
  baseline_parent="$(git -C "${REPO_ROOT}" rev-parse "${ACTIVE_CHANGE_COMMIT}^" 2>/dev/null)" || return 1
  [[ "${parent_head}" == "${ACTIVE_CHANGE_COMMIT}" ]] || return 1
  git -C "${REPO_ROOT}" diff --quiet "${baseline_parent}" "${current_head}" -- "${VALUES_RELATIVE}" || return 1
  ACTIVE_ROLLBACK_COMMIT="${current_head}"
}

emergency_git_cleanup() {
  local current_head rollback_commit
  [[ -n "${ACTIVE_CHANGE_COMMIT}" ]] || return 0

  log "Emergency cleanup: restoring the Git baseline for experimental commit ${ACTIVE_CHANGE_COMMIT}"
  if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=no)" ]]; then
    log "Emergency cleanup refused: tracked files changed after the experiment commit; inspect them and revert ${ACTIVE_CHANGE_COMMIT} manually"
    return 1
  fi

  current_head="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null)" || {
    log "Emergency cleanup failed: cannot resolve local HEAD"
    return 1
  }

  if [[ -n "${ACTIVE_ROLLBACK_COMMIT}" && "${current_head}" == "${ACTIVE_ROLLBACK_COMMIT}" ]]; then
    rollback_commit="${ACTIVE_ROLLBACK_COMMIT}"
    log "Emergency cleanup found the already-created rollback commit ${rollback_commit}"
  elif existing_rollback_for_active_change; then
    rollback_commit="${ACTIVE_ROLLBACK_COMMIT}"
    log "Emergency cleanup detected the already-created rollback commit ${rollback_commit}"
  elif [[ "${current_head}" == "${ACTIVE_CHANGE_COMMIT}" ]]; then
    if ! git -C "${REPO_ROOT}" revert --no-edit "${ACTIVE_CHANGE_COMMIT}" >>"${CURRENT_LOG}" 2>&1; then
      log "Emergency cleanup failed to create a rollback commit; inspect ${CURRENT_LOG} and revert ${ACTIVE_CHANGE_COMMIT} manually"
      return 1
    fi
    rollback_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
    ACTIVE_ROLLBACK_COMMIT="${rollback_commit}"
    log "Emergency cleanup created rollback commit ${rollback_commit}"
  else
    log "Emergency cleanup refused: HEAD moved from ${ACTIVE_CHANGE_COMMIT} to ${current_head}; no automatic revert was attempted"
    return 1
  fi

  # Once a rollback commit exists, never try to create a second one. If the
  # push fails, keep this local commit so the operator can retry it directly.
  ACTIVE_CHANGE_COMMIT=""
  if ! git -C "${REPO_ROOT}" push "${GIT_REMOTE}" "HEAD:${GIT_BRANCH}" >>"${CURRENT_LOG}" 2>&1; then
    log "Emergency rollback push failed; local rollback commit ${rollback_commit} was retained. The remote may still contain the experimental change; retry: git push ${GIT_REMOTE} HEAD:${GIT_BRANCH}"
    return 1
  fi
  ACTIVE_ROLLBACK_COMMIT=""
  LAST_GIT_COMMIT="${rollback_commit}"
  log "Emergency cleanup pushed rollback commit ${rollback_commit}; the Git baseline is restored"
}

git_cleanup_on_exit() {
  local original_status="$1"
  local cleanup_status=0
  trap - EXIT INT TERM
  GIT_CLEANUP_TRAPS_INSTALLED=false
  if [[ -n "${ACTIVE_CHANGE_COMMIT}" ]]; then
    emergency_git_cleanup || cleanup_status=$?
  fi
  if (( original_status == 0 && cleanup_status != 0 )); then
    original_status="${cleanup_status}"
  fi
  exit "${original_status}"
}

values_get() {
  python3 "${VALUES_EDITOR}" get --file "${VALUES_FILE}" --service "${SERVICE}" --field "$1"
}

values_set() {
  python3 "${VALUES_EDITOR}" set --file "${VALUES_FILE}" --service "${SERVICE}" --field "$1" --value "$2"
}

commit_and_push_values() {
  local message="$1"
  local commit
  git -C "${REPO_ROOT}" add -- "${VALUES_RELATIVE}"
  git -C "${REPO_ROOT}" diff --cached --quiet && die "The requested values update produced no Git change"
  git -C "${REPO_ROOT}" commit -m "${message}" >>"${CURRENT_LOG}" 2>&1
  commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  log "Created commit ${commit}; pushing to ${GIT_REMOTE}/${GIT_BRANCH}"
  git -C "${REPO_ROOT}" push "${GIT_REMOTE}" "HEAD:${GIT_BRANCH}" >>"${CURRENT_LOG}" 2>&1 || \
    die "Git push failed; local commit ${commit} was retained for diagnosis"
  LAST_GIT_COMMIT="${commit}"
  arm_git_cleanup "${commit}"
}

revert_and_push() {
  local commit="$1"
  git -C "${REPO_ROOT}" revert --no-edit "${commit}" >>"${CURRENT_LOG}" 2>&1 || \
    die "Could not create a Git rollback commit for ${commit}"
  local revert_commit
  revert_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  if [[ "${ACTIVE_CHANGE_COMMIT}" == "${commit}" ]]; then
    ACTIVE_ROLLBACK_COMMIT="${revert_commit}"
  fi
  log "Created rollback commit ${revert_commit}; pushing to ${GIT_REMOTE}/${GIT_BRANCH}"
  if ! git -C "${REPO_ROOT}" push "${GIT_REMOTE}" "HEAD:${GIT_BRANCH}" >>"${CURRENT_LOG}" 2>&1; then
    # Keep both commit identifiers armed. The EXIT handler recognizes the
    # existing rollback and retries only the push; it never creates a second
    # revert. A second failure still leaves the exact local recovery commit.
    die "Git rollback push failed; emergency cleanup will retry the existing rollback commit ${revert_commit} once"
  fi
  disarm_git_cleanup
  LAST_GIT_COMMIT="${revert_commit}"
}
