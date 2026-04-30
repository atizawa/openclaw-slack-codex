#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="${repo_root}/workspaces"
agent_root="${repo_root}/config/agents"

usage() {
  cat <<'USAGE'
Usage:
  scripts/workspace-session-invalidator.sh [workspace ...]
  scripts/workspace-session-invalidator.sh --all

Clears stored sessions for the given workspace(s). Set
WORKSPACE_SESSION_INVALIDATOR_RESTART=1 to restart OpenClaw after cleanup.
USAGE
}

restart_openclaw() {
  if [ "${WORKSPACE_SESSION_INVALIDATOR_RESTART:-0}" = "1" ]; then
    docker compose restart openclaw >/dev/null
  fi
}

invalidate_workspace_sessions() {
  local workspace_name="$1"

  if ! docker compose exec -T openclaw openclaw sessions cleanup \
    --agent "$workspace_name" \
    --fix-missing \
    --enforce >/dev/null; then
    echo "Warning: OpenClaw is not available; cleared session files only: ${workspace_name}" >&2
  fi
}

reset_workspace_sessions() {
  local workspace_name="$1"
  local sessions_dir="${agent_root}/${workspace_name}/sessions"

  rm -rf "$sessions_dir"
  mkdir -p "$sessions_dir"
  printf '{}\n' > "${sessions_dir}/sessions.json"
  echo "Cleared sessions for workspace: ${workspace_name}"
}

list_workspaces() {
  find "$workspace_root" -mindepth 1 -maxdepth 1 -type d \
    ! -name '.*' \
    | sed 's#.*/##' \
    | LC_ALL=C sort
}

is_valid_workspace() {
  local workspace_name="$1"

  case "$workspace_name" in
    ""|"."|".."|*/*)
      return 1
      ;;
  esac

  list_workspaces | grep -Fx -- "$workspace_name" >/dev/null
}

main() {
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
  fi

  cd "$repo_root"

  local workspaces=()
  if [ "${1:-}" = "--all" ] || [ "$#" -eq 0 ]; then
    while IFS= read -r workspace_name; do
      [ -n "$workspace_name" ] && workspaces+=("$workspace_name")
    done < <(list_workspaces)
  else
    workspaces=("$@")
  fi

  local did_change=0
  local workspace_name
  for workspace_name in "${workspaces[@]}"; do
    if ! is_valid_workspace "$workspace_name"; then
      echo "Skipping invalid or missing workspace: ${workspace_name}" >&2
      continue
    fi

    reset_workspace_sessions "$workspace_name"
    invalidate_workspace_sessions "$workspace_name"
    did_change=1
  done

  if [ "$did_change" -eq 1 ]; then
    restart_openclaw
  fi
}

main "$@"
