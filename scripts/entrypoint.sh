#!/usr/bin/env bash
set -euo pipefail

SOURCE_WORKSPACES_DIR="/home/node/.openclaw/workspaces-source"
STATE_DIR="/home/node/.openclaw/state"
WORKSPACES_DIR="${STATE_DIR}/runtime-workspaces"
STATE_WORKSPACES_DIR="${STATE_DIR}/workspaces"
CHANNELS_CONF="${SOURCE_WORKSPACES_DIR}/channels.conf"
CONFIG_DIR="/home/node/.openclaw"
GENERATED_CONFIG="${CONFIG_DIR}/openclaw.json"
BASE_CONFIG="${CONFIG_DIR}/openclaw.base.json"

copy_seed_if_missing() {
  local source_path="$1"
  local state_path="$2"

  if [ -e "$state_path" ] || [ -L "$state_path" ]; then
    return
  fi

  if [ -d "$source_path" ]; then
    cp -a "$source_path" "$state_path"
  elif [ -e "$source_path" ]; then
    mkdir -p "$(dirname "$state_path")"
    cp -a "$source_path" "$state_path"
  fi
}

is_writable_state_item() {
  case "$1" in
    .openclaw|memory|SOUL.md|HEARTBEAT.md|BOOTSTRAP.md|IDENTITY.md|USER.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_ignored_runtime_item() {
  case "$1" in
    .git|.codex|.DS_Store)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

link_workspace_item() {
  local source_item="$1"
  local runtime_item="$2"
  local state_item="$3"
  local item_name
  item_name="$(basename "$source_item")"

  if is_writable_state_item "$item_name"; then
    copy_seed_if_missing "$source_item" "$state_item"
    if [ -e "$state_item" ] || [ -L "$state_item" ]; then
      ln -s "$state_item" "$runtime_item"
    fi
  else
    ln -s "$source_item" "$runtime_item"
  fi
}

prepare_runtime_workspaces() {
  rm -rf "$WORKSPACES_DIR"
  mkdir -p "$WORKSPACES_DIR" "$STATE_WORKSPACES_DIR"

  if [ ! -d "$SOURCE_WORKSPACES_DIR" ]; then
    echo "Warning: source workspaces directory not found: $SOURCE_WORKSPACES_DIR" >&2
    return
  fi

  for source_workspace in "${SOURCE_WORKSPACES_DIR}"/*/; do
    [ -d "$source_workspace" ] || continue
    source_workspace="${source_workspace%/}"

    local name
    name="$(basename "$source_workspace")"

    local runtime_workspace="${WORKSPACES_DIR}/${name}"
    local state_workspace="${STATE_WORKSPACES_DIR}/${name}"
    rm -rf "$runtime_workspace"
    mkdir -p "$runtime_workspace" "$state_workspace"

    local item
    for item in "$source_workspace"/* "$source_workspace"/.[!.]* "$source_workspace"/..?*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      local item_name
      item_name="$(basename "$item")"
      if is_ignored_runtime_item "$item_name"; then
        continue
      fi
      link_workspace_item \
        "$item" \
        "${runtime_workspace}/${item_name}" \
        "${state_workspace}/${item_name}"
    done
  done
}

# Build agents list and bindings from channels.conf + workspace directories
generate_config() {
  local agents_list=""
  local bindings=""
  local slack_channels=""

  # Default agent (fallback for DMs and unmatched channels). Runtime
  # workspaces are generated under the writable state directory.
  if [ ! -d "${WORKSPACES_DIR}/default" ]; then
    mkdir -p "${WORKSPACES_DIR}/default"
  fi

  agents_list="$(cat <<AGENT
    {
      "id": "default",
      "name": "Default Agent",
      "default": true,
      "workspace": "${WORKSPACES_DIR}/default"
    }
AGENT
)"

  # Read channels.conf if it exists
  if [ -f "$CHANNELS_CONF" ]; then
    while IFS='=' read -r workspace_name channel_id || [ -n "$workspace_name" ]; do
      # Skip empty lines and comments
      [[ -z "$workspace_name" || "$workspace_name" =~ ^[[:space:]]*# ]] && continue

      # Trim whitespace
      workspace_name="$(echo "$workspace_name" | xargs)"
      channel_id="$(echo "$channel_id" | xargs)"

      # Skip if workspace directory doesn't exist
      if [ ! -d "${WORKSPACES_DIR}/${workspace_name}" ]; then
        echo "Warning: workspace '${workspace_name}' in channels.conf but directory not found, skipping" >&2
        continue
      fi

      # Skip if channel_id is empty
      if [ -z "$channel_id" ]; then
        echo "Warning: workspace '${workspace_name}' has no channel ID, skipping" >&2
        continue
      fi

      agents_list="${agents_list},
    {
      \"id\": \"${workspace_name}\",
      \"name\": \"${workspace_name}\",
      \"workspace\": \"${WORKSPACES_DIR}/${workspace_name}\"
    }"

      bindings="${bindings}${bindings:+,}
    {
      \"agentId\": \"${workspace_name}\",
      \"match\": {
        \"channel\": \"slack\",
        \"peer\": { \"kind\": \"channel\", \"id\": \"${channel_id}\" }
      }
    }"

      slack_channels="${slack_channels}${slack_channels:+,}
      \"${channel_id}\": {
        \"enabled\": true,
        \"requireMention\": true
      }"
    done < "$CHANNELS_CONF"
  fi

  # Also register workspaces without channel mapping (accessible via default routing)
  if [ -d "$WORKSPACES_DIR" ]; then
    for dir in "${WORKSPACES_DIR}"/*/; do
      [ ! -d "$dir" ] && continue
      local name
      name="$(basename "$dir")"
      [ "$name" = "default" ] && continue
      # Skip if already registered via channels.conf
      if echo "$agents_list" | grep -q "\"id\": \"${name}\""; then
        continue
      fi
      agents_list="${agents_list},
    {
      \"id\": \"${name}\",
      \"name\": \"${name}\",
      \"workspace\": \"${WORKSPACES_DIR}/${name}\"
    }"
    done
  fi

  # Default binding (fallback) - must be last
  bindings="${bindings}${bindings:+,}
    {
      \"agentId\": \"default\",
      \"match\": { \"channel\": \"slack\" }
    }"

  # Read base config and inject agents + bindings
  local base
  base="$(cat "$BASE_CONFIG")"

  # Generate final config using node for reliable JSON merging
  node -e "
    const base = JSON.parse(process.argv[1]);
    const agents = [${agents_list}];
    const bindings = [${bindings}];
    const slackChannels = {${slack_channels}};
    base.agents = base.agents || {};
    base.agents.list = agents;
    base.bindings = bindings;
    if (Object.keys(slackChannels).length > 0) {
      base.channels = base.channels || {};
      base.channels.slack = base.channels.slack || {};
      base.channels.slack.groupPolicy = base.channels.slack.groupPolicy || 'allowlist';
      base.channels.slack.channels = {
        ...(base.channels.slack.channels || {}),
        ...slackChannels,
      };
    }
    console.log(JSON.stringify(base, null, 2));
  " "$base" > "$GENERATED_CONFIG"

  echo "Generated openclaw.json with $(echo "[${agents_list}]" | node -e "console.log(JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).length)") agent(s)"
}

prepare_runtime_workspaces
generate_config

# Configure Codex CLI sandbox mode. The default avoids the bwrap-based sandbox,
# which is not portable across Docker environments. Filesystem access is bounded
# by Docker mounts; workspaces are mounted read-only in docker-compose.yml.
CODEX_CONFIG="/home/node/.codex/config.toml"
CODEX_SANDBOX_MODE="${CODEX_SANDBOX_MODE:-danger-full-access}"
if ! grep -q '^sandbox_mode' "$CODEX_CONFIG" 2>/dev/null; then
  echo '' >> "$CODEX_CONFIG"
  echo "sandbox_mode = \"${CODEX_SANDBOX_MODE}\"" >> "$CODEX_CONFIG"
  echo "Added sandbox_mode = ${CODEX_SANDBOX_MODE} to Codex config"
elif ! grep -q "^sandbox_mode = \"${CODEX_SANDBOX_MODE}\"" "$CODEX_CONFIG"; then
  sed -i "s/^sandbox_mode = .*/sandbox_mode = \"${CODEX_SANDBOX_MODE}\"/" "$CODEX_CONFIG"
  echo "Updated sandbox_mode to ${CODEX_SANDBOX_MODE} in Codex config"
fi

# Execute the original entrypoint with CMD
exec docker-entrypoint.sh "$@"
