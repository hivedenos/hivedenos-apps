#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/channels/lib.sh"
init_channel_context "$ROOT_DIR"

pipeline_file="$CHANNELS_PIPELINE_FILE"
apps_root_rel="$CHANNELS_APPS_ROOT_REL"
apps_root="$CHANNELS_APPS_ROOT"

usage() {
  echo "Usage: $0 <app-id> <channel> [source-id]" >&2
  echo "Example: $0 btc-rpc-explorer beta" >&2
  echo "Example: $0 nostr-relay incubator umbrel" >&2
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 1
fi

app_id="$1"
channel="$2"
source_id="${3:-*}"

if [[ -z "$app_id" || -z "$channel" ]]; then
  usage
  exit 1
fi

validate_channel_name "$channel" "$pipeline_file"

resolved_source_id="$source_id"
if [[ "$channel" == "incubator" && "$resolved_source_id" == "*" ]]; then
  resolved_source_id="$(resolve_incubator_source_id "$app_id" false "$apps_root")"
fi

target_rel="$(channel_app_rel_path "$channel" "$app_id" "$resolved_source_id" "$apps_root_rel")"
source_root="$(channel_source_root_abs_path "$ROOT_DIR" "$channel" "$resolved_source_id" "$apps_root_rel")"

target_abs="$ROOT_DIR/$target_rel"

if [[ ! -d "$target_abs" ]]; then
  echo "App directory does not exist in channel '$channel': $target_rel" >&2
  exit 1
fi

rm -rf "$target_abs"

remove_empty_incubator_source_root "$source_root"

bash "$ROOT_DIR/scripts/channels/rebuild-catalog.sh" "$ROOT_DIR"

echo "Removed app directory: $target_rel"
echo "Updated catalog outputs: data/apps.json and data/metadata.json"
