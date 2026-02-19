#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
pipeline_file="$ROOT_DIR/config/pipeline.json"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

merged_json="$work_dir/merged.json"
resolved_json="$work_dir/resolved-channel-placements.json"
catalog_rel="$(jq -r '.output.catalog // "data/apps.json"' "$pipeline_file")"
metadata_rel="$(jq -r '.output.metadata // "data/metadata.json"' "$pipeline_file")"
catalog_path="$ROOT_DIR/$catalog_rel"
metadata_path="$ROOT_DIR/$metadata_rel"

mkdir -p "$(dirname "$catalog_path")" "$(dirname "$metadata_path")"

"$ROOT_DIR/scripts/pipeline/merge-sources.sh" "$ROOT_DIR" "$merged_json"
bash "$ROOT_DIR/scripts/pipeline/resolve-channel-placements.sh" "$ROOT_DIR" "$merged_json" "$resolved_json"
"$ROOT_DIR/scripts/pipeline/build-catalog.sh" "$ROOT_DIR" "$resolved_json" "$catalog_path" "$metadata_path"
"$ROOT_DIR/scripts/pipeline/validate.sh" "$ROOT_DIR"
