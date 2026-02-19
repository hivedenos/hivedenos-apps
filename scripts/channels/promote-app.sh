#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pipeline_file="$ROOT_DIR/config/pipeline.json"
overrides_file="$ROOT_DIR/config/channel-overrides.json"
apps_root_rel="$(jq -r '.output.apps_root // "apps"' "$pipeline_file")"
apps_root="$ROOT_DIR/$apps_root_rel"

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

validate_channel() {
  local channel="$1"
  if ! jq -e --arg channel "$channel" '.channels.definitions | has($channel)' "$pipeline_file" >/dev/null; then
    echo "Invalid channel: $channel" >&2
    echo "Allowed channels:" >&2
    jq -r '.channels.order[]' "$pipeline_file" >&2
    exit 1
  fi
}

validate_channel "$from_channel"
validate_channel "$to_channel"

resolve_source_id_from_incubator() {
  local id="$1"
  local allow_none="${2:-false}"
  mapfile -t matches < <(find "$apps_root/incubator" -mindepth 2 -maxdepth 2 -type d -name "$id" | sort)

  if [[ ${#matches[@]} -eq 0 ]]; then
    if [[ "$allow_none" == "true" ]]; then
      printf '\n'
      return 0
    fi
    echo "No incubator app directory found for app: $id" >&2
    exit 1
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    echo "Multiple incubator app directories found for app: $id" >&2
    echo "Please provide [source-id] explicitly." >&2
    printf '%s\n' "${matches[@]#$apps_root/}" >&2
    exit 1
  fi

  basename "$(dirname "${matches[0]}")"
}

normalize_image_dir() {
  local app_dir="$1"
  local img_dir="$app_dir/img"
  local legacy_imgs_dir="$app_dir/imgs"

  if [[ ! -d "$legacy_imgs_dir" ]]; then
    return 0
  fi

  if [[ -d "$img_dir" ]]; then
    while IFS= read -r legacy_file; do
      base_name="$(basename "$legacy_file")"
      if [[ ! -e "$img_dir/$base_name" ]]; then
        mv "$legacy_file" "$img_dir/$base_name"
      fi
    done < <(find "$legacy_imgs_dir" -mindepth 1 -maxdepth 1 -type f | sort)
    rm -rf "$legacy_imgs_dir"
  else
    mv "$legacy_imgs_dir" "$img_dir"
  fi
}

resolved_source_id="$source_id"

if [[ "$from_channel" == "incubator" && "$resolved_source_id" == "*" ]]; then
  resolved_source_id="$(resolve_source_id_from_incubator "$app_id")"
fi

if [[ "$to_channel" == "incubator" && "$resolved_source_id" == "*" ]]; then
  resolved_source_id="$(resolve_source_id_from_incubator "$app_id" true)"
fi

if [[ "$from_channel" == "incubator" ]]; then
  src_rel="$apps_root_rel/incubator/$resolved_source_id/$app_id"
else
  src_rel="$apps_root_rel/$from_channel/$app_id"
fi

if [[ "$to_channel" == "incubator" ]]; then
  if [[ "$resolved_source_id" == "*" ]]; then
    echo "A concrete source-id is required when promoting into incubator if no incubator source copy exists." >&2
    exit 1
  fi
  dst_rel="$apps_root_rel/incubator/$resolved_source_id/$app_id"
else
  dst_rel="$apps_root_rel/$to_channel/$app_id"
fi

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

normalize_image_dir "$dst_abs"

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

echo "$action app directory: $src_rel -> $dst_rel"
echo "Recorded promotion override: $app_id $from_channel -> $to_channel (source: $resolved_source_id)"
echo "Run ./scripts/run-sync.sh to regenerate data/apps.json from channel directories."
