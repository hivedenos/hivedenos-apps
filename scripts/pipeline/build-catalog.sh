#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"
MERGED_JSON="$2"
CATALOG_OUT="$3"
METADATA_OUT="$4"

catalog_version="$(jq -r '.catalog_version' "$ROOT_DIR/config/pipeline.json")"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg version "$catalog_version" \
  --arg generated_at "$generated_at" \
  --slurpfile apps "$MERGED_JSON" \
  '{
    version: $version,
    generated_at: $generated_at,
    total_apps: ($apps[0] | length),
    apps: $apps[0]
  }' >"$CATALOG_OUT"

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
  --argjson total_apps "$(jq '.total_apps' "$CATALOG_OUT")" \
  '{
    generated_at: $generated_at,
    total_apps: $total_apps,
    catalog_sha256: $catalog_sha256,
    sources: $sources
  }' >"$METADATA_OUT"
