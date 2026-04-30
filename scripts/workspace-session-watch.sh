#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="${repo_root}/workspaces"
state_root="${repo_root}/state/workspace-fingerprints"

interval_seconds="${1:-5}"
invalidate_on_start="${WORKSPACE_SESSION_WATCH_INVALIDATE_ON_START:-0}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/workspace-session-watch.sh [interval_seconds]

Polls workspaces and clears sessions when workspace files change.
Set WORKSPACE_SESSION_WATCH_INVALIDATE_ON_START=1 to clear existing
sessions after writing initial fingerprints.
USAGE
}

hash_workspace() {
  local workspace_path="$1"
  local workspace_root_real
  workspace_root_real="$(cd "$workspace_root" && pwd -P)"

  (
    cd "$workspace_path"
    find -L . -mindepth 1 \
      \( -name .git -o -name .codex -o -name .DS_Store \) -prune -o \
      -type f -print 2>/dev/null \
      | while IFS= read -r file; do
          physical_dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)" || continue
          physical_path="${physical_dir}/$(basename "$file")"
          case "$physical_path" in
            "$workspace_root_real"/*)
              shasum -a 256 "$file" | awk -v path="$file" '{print $1 "  " path}'
              ;;
            *)
              echo "Skipping file outside workspace root: ${workspace_path}/${file#./}" >&2
              ;;
          esac
        done \
      | LC_ALL=C sort \
      | shasum -a 256 \
      | awk '{print $1}'
  )
}

list_workspaces() {
  find "$workspace_root" -mindepth 1 -maxdepth 1 -type d \
    ! -name '.*' \
    | sed 's#.*/##' \
    | LC_ALL=C sort
}

ensure_state_dir() {
  mkdir -p "$state_root"
}

fingerprint_file() {
  local workspace_name="$1"
  printf '%s/%s.sha256' "$state_root" "$workspace_name"
}

main() {
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
  fi

  ensure_state_dir
  while true; do
    local workspace_name
    local -a changed_workspaces=()
    local -a initial_workspaces=()
    while IFS= read -r workspace_name; do
      [ -n "$workspace_name" ] || continue
      [ -d "${workspace_root}/${workspace_name}" ] || continue
      local fingerprint_path current_hash previous_hash
      fingerprint_path="$(fingerprint_file "$workspace_name")"
      current_hash="$(hash_workspace "${workspace_root}/${workspace_name}")"
      if [ ! -f "$fingerprint_path" ]; then
        printf '%s\n' "$current_hash" > "$fingerprint_path"
        initial_workspaces+=("$workspace_name")
        continue
      fi
      previous_hash="$(cat "$fingerprint_path")"
      if [ "$current_hash" != "$previous_hash" ]; then
        changed_workspaces+=("$workspace_name")
      fi
    done < <(list_workspaces)

    if [ "$invalidate_on_start" = "1" ]; then
      if [ "${#initial_workspaces[@]}" -gt 0 ]; then
        printf 'Initial workspace fingerprints created: %s\n' "${initial_workspaces[*]}"
        "${repo_root}/scripts/workspace-session-invalidator.sh" "${initial_workspaces[@]}"
      fi
      invalidate_on_start=0
    fi

    if [ "${#changed_workspaces[@]}" -gt 0 ]; then
      printf 'Workspace changes detected: %s\n' "${changed_workspaces[*]}"
      "${repo_root}/scripts/workspace-session-invalidator.sh" "${changed_workspaces[@]}"
      for workspace_name in "${changed_workspaces[@]}"; do
        printf '%s\n' "$(hash_workspace "${workspace_root}/${workspace_name}")" > "$(fingerprint_file "$workspace_name")"
      done
    fi

    sleep "$interval_seconds"
  done
}

main "$@"
