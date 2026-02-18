#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"
MERGED_JSON="$2"
CATALOG_OUT="$3"
METADATA_OUT="$4"

catalog_version="$(jq -r '.catalog_version' "$ROOT_DIR/config/pipeline.json")"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
default_channel="$(jq -r '.channels.default // "stable"' "$ROOT_DIR/config/pipeline.json")"
channel_order_json="$(jq -c '.channels.order // ["stable", "beta", "edge", "incubator"]' "$ROOT_DIR/config/pipeline.json")"
channel_defs_json="$(jq -c '.channels.definitions // {}' "$ROOT_DIR/config/pipeline.json")"

jq -n \
  --arg version "$catalog_version" \
  --arg generated_at "$generated_at" \
  --arg default_channel "$default_channel" \
  --argjson channel_order "$channel_order_json" \
  --argjson channel_defs "$channel_defs_json" \
  --slurpfile apps "$MERGED_JSON" \
  '
  ($apps[0] // []) as $all_apps
  | (reduce $channel_order[] as $ch ({}; .[$ch] = ($all_apps | map(select((.channel // "stable") == $ch)))) ) as $apps_by_channel
  | (reduce $channel_order[] as $ch ({}; .[$ch] = {
      total_apps: ($apps_by_channel[$ch] | length),
      warning: ($channel_defs[$ch].warning // null)
    })) as $channels
  | ($apps_by_channel[$default_channel] // []) as $default_apps
  | {
      version: $version,
      generated_at: $generated_at,
      default_channel: $default_channel,
      total_apps: ($default_apps | length),
      total_apps_all_channels: ($all_apps | length),
      channels: $channels,
      apps: $default_apps,
      apps_by_channel: $apps_by_channel
    }
  ' >"$CATALOG_OUT"

mapfile -t source_meta_files < <(find "$ROOT_DIR/data/sources" -mindepth 2 -maxdepth 2 -type f -name 'metadata.json' | sort)
if [[ ${#source_meta_files[@]} -gt 0 ]]; then
  sources_json="$(jq -s '.' "${source_meta_files[@]}")"
else
  sources_json='[]'
fi

catalog_sha256="$(sha256sum "$CATALOG_OUT" | awk '{print $1}')"

jq -n \
  --arg generated_at "$generated_at" \
  --arg catalog_sha256 "$catalog_sha256" \
  --argjson sources "$sources_json" \
  --argjson channels "$(jq '.channels' "$CATALOG_OUT")" \
  --argjson total_apps "$(jq '.total_apps_all_channels // .total_apps' "$CATALOG_OUT")" \
  '{
    generated_at: $generated_at,
    total_apps: $total_apps,
    catalog_sha256: $catalog_sha256,
    channels: $channels,
    sources: $sources
  }' >"$METADATA_OUT"
