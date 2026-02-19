#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/channels/lib.sh"
init_channel_context "$ROOT_DIR"

pipeline_file="$CHANNELS_PIPELINE_FILE"
overrides_file="$ROOT_DIR/config/channel-overrides.json"
apps_root_rel="$CHANNELS_APPS_ROOT_REL"
apps_root="$CHANNELS_APPS_ROOT"

usage() {
  echo "Usage: $0 <app-id> <from-channel> <to-channel> [source-id]" >&2
  echo "Example: $0 btc-rpc-explorer edge beta umbrel" >&2
}

if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage
  exit 1
fi

app_id="$1"
from_channel="$2"
to_channel="$3"
source_id="${4:-*}"

if [[ -z "$app_id" || -z "$from_channel" || -z "$to_channel" ]]; then
  usage
  exit 1
fi

if [[ "$from_channel" == "$to_channel" ]]; then
  echo "Source and destination channels are the same: $from_channel" >&2
  exit 1
fi

validate_channel_name "$from_channel" "$pipeline_file"
validate_channel_name "$to_channel" "$pipeline_file"

resolved_source_id="$source_id"

if [[ "$from_channel" == "incubator" && "$resolved_source_id" == "*" ]]; then
  resolved_source_id="$(resolve_incubator_source_id "$app_id" false "$apps_root")"
fi

if [[ "$to_channel" == "incubator" && "$resolved_source_id" == "*" ]]; then
  resolved_source_id="$(resolve_incubator_source_id "$app_id" true "$apps_root")"
fi

if [[ "$to_channel" == "incubator" ]]; then
  if [[ "$resolved_source_id" == "*" ]]; then
    echo "A concrete source-id is required when promoting into incubator if no incubator source copy exists." >&2
    exit 1
  fi
fi

src_rel="$(channel_app_rel_path "$from_channel" "$app_id" "$resolved_source_id" "$apps_root_rel")"
dst_rel="$(channel_app_rel_path "$to_channel" "$app_id" "$resolved_source_id" "$apps_root_rel")"

src_abs="$ROOT_DIR/$src_rel"
dst_abs="$ROOT_DIR/$dst_rel"

if [[ ! -d "$src_abs" ]]; then
  echo "Source app directory does not exist: $src_rel" >&2
  exit 1
fi

if [[ -e "$dst_abs" ]]; then
  echo "Destination app directory already exists: $dst_rel" >&2
  exit 1
fi

mkdir -p "$(dirname "$dst_abs")"

if [[ "$from_channel" == "incubator" ]]; then
  cp -a "$src_abs" "$dst_abs"
  action="Copied"
else
  mv "$src_abs" "$dst_abs"
  action="Moved"
fi

normalize_app_image_dir "$dst_abs"
customize_app_dir_for_hiveden "$dst_abs"

if [[ ! -f "$overrides_file" ]]; then
  jq -n '{version: "1.0.0", overrides: []}' >"$overrides_file"
fi

now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp_file="$(mktemp)"

jq \
  --arg id "$app_id" \
  --arg source_id "$resolved_source_id" \
  --arg from_channel "$from_channel" \
  --arg channel "$to_channel" \
  --arg updated_at "$now_utc" \
  '
  .version = (.version // "1.0.0")
  | .overrides = (
      ((.overrides // []) | map(select(.id != $id or ((.source_id // "*") != $source_id))))
      + [{
          id: $id,
          source_id: $source_id,
          from_channel: $from_channel,
          channel: $channel,
          promotion_status: "promoted",
          updated_at: $updated_at
        }]
    )
  | .overrides |= sort_by(.id, (.source_id // "*"))
  ' "$overrides_file" >"$tmp_file"

mv "$tmp_file" "$overrides_file"
bash "$ROOT_DIR/scripts/channels/rebuild-catalog.sh" "$ROOT_DIR"

echo "$action app directory: $src_rel -> $dst_rel"
echo "Recorded promotion override: $app_id $from_channel -> $to_channel (source: $resolved_source_id)"
echo "Updated catalog outputs: data/apps.json and data/metadata.json"
