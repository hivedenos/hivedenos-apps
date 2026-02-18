#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"
SOURCE_ID="$2"
NORMALIZED_JSON="$3"

overrides_file="$ROOT_DIR/config/channel-overrides.json"
pipeline_file="$ROOT_DIR/config/pipeline.json"

if [[ ! -f "$NORMALIZED_JSON" ]]; then
  echo "Missing normalized input: $NORMALIZED_JSON" >&2
  exit 1
fi

if [[ ! -f "$overrides_file" ]]; then
  jq -n '{version: "1.0.0", overrides: []}' >"$overrides_file"
fi

channel_defs_json="$(jq -c '.channels.definitions // {}' "$pipeline_file")"
overrides_json="$(jq -c '.overrides // []' "$overrides_file")"

tmp_out="$(mktemp)"

jq \
  --arg source_id "$SOURCE_ID" \
  --argjson channel_defs "$channel_defs_json" \
  --argjson overrides "$overrides_json" \
  '
  def valid_channel($c): ($channel_defs | has($c));

  def resolved_channel($app; $override):
    ($override.channel // $app.channel // "incubator") as $candidate
    | if valid_channel($candidate) then $candidate else "incubator" end;

  def resolved_override($app):
    ($overrides
      | map(select(
          .id == $app.id
          and (((.source_id // "*") == "*") or ((.source_id // "*") == $source_id))
      ))
      | sort_by((if (.source_id // "*") == $source_id then 0 else 1 end), (.updated_at // ""))
      | .[0]);

  map(
    . as $app
    | (resolved_override($app)) as $override
    | (resolved_channel($app; $override)) as $channel
    | ($channel_defs[$channel] // $channel_defs["stable"] // {}) as $meta
    | .origin_channel = (.origin_channel // .channel // "stable")
    | .channel = $channel
    | .channel_label = ($meta.label // $channel)
    | .risk_level = ($meta.risk_level // "unknown")
    | .support_tier = ($meta.support_tier // "community")
    | .promotion_status = (
        if $override == null then
          (.promotion_status // "none")
        else
          ($override.promotion_status // "promoted")
        end
      )
    | .repository_path = (
        if $channel == "incubator" then
          "apps/incubator/" + $source_id + "/" + .id
        else
          "apps/" + $channel + "/" + .id
        end
      )
  )
  ' "$NORMALIZED_JSON" >"$tmp_out"

mv "$tmp_out" "$NORMALIZED_JSON"
