#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pipeline_file="$ROOT_DIR/config/pipeline.json"
overrides_file="$ROOT_DIR/config/channel-overrides.json"

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

if [[ ! -f "$overrides_file" ]]; then
  jq -n '{version: "1.0.0", overrides: []}' >"$overrides_file"
fi

now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp_file="$(mktemp)"

jq \
  --arg id "$app_id" \
  --arg source_id "$source_id" \
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

echo "Recorded promotion override: $app_id $from_channel -> $to_channel (source: $source_id)"
echo "Run ./scripts/run-sync.sh to apply updated channel placements."
