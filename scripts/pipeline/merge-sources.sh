#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"
OUT_JSON="$2"

mapfile -t normalized_files < <(find "$ROOT_DIR/data/sources" -mindepth 2 -maxdepth 2 -type f -name 'normalized.json' | sort)

if [[ ${#normalized_files[@]} -eq 0 ]]; then
  echo '[]' >"$OUT_JSON"
  exit 0
fi

jq -s \
  --argjson priorities "$(jq '.sources | map({(.id): .priority}) | add' "$ROOT_DIR/config/sources.json")" \
  --argjson channel_order "$(jq '.channels.order // ["stable", "beta", "edge", "incubator"]' "$ROOT_DIR/config/pipeline.json")" \
  '
  def channel_rank($channel): ($channel_order | index($channel)) // 999999;

  [ .[] | .[] ]
  | sort_by(channel_rank(.channel // "stable"), ($priorities[.source.id] // 999999), .id, .source.id)
  | reduce .[] as $app (
      [];
      if ($app.channel // "stable") == "incubator" then
        . + [$app]
      elif any(.[]; (.channel // "stable") == ($app.channel // "stable") and .id == $app.id) then
        .
      else
        . + [$app]
      end
    )
  | sort_by(channel_rank(.channel // "stable"), .id, .source.id)
  ' "${normalized_files[@]}" >"$OUT_JSON"
