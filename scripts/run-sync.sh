#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/log.sh
source "$ROOT_DIR/scripts/lib/log.sh"
# shellcheck source=lib/json.sh
source "$ROOT_DIR/scripts/lib/json.sh"

require_jq

sources_file="$ROOT_DIR/config/sources.json"
work_base="$(mktemp -d)"
trap 'rm -rf "$work_base"' EXIT

log_info "Starting app sync pipeline"

mapfile -t source_ids < <(jq -r '.sources[] | select(.enabled == true) | .id' "$sources_file")
if [[ ${#source_ids[@]} -eq 0 ]]; then
  log_warn "No enabled sources found. Generating empty catalog."
fi

apps_root_rel="$(jq -r '.output.apps_root // "apps"' "$ROOT_DIR/config/pipeline.json")"
apps_root="$ROOT_DIR/$apps_root_rel"
sources_root_rel="$(jq -r '.output.sources_root // "data/sources"' "$ROOT_DIR/config/pipeline.json")"
sources_root="$ROOT_DIR/$sources_root_rel"
catalog_rel="$(jq -r '.output.catalog // "data/apps.json"' "$ROOT_DIR/config/pipeline.json")"
metadata_rel="$(jq -r '.output.metadata // "data/metadata.json"' "$ROOT_DIR/config/pipeline.json")"
catalog_path="$ROOT_DIR/$catalog_rel"
metadata_path="$ROOT_DIR/$metadata_rel"
catalog_dir="$(dirname "$catalog_path")"
metadata_dir="$(dirname "$metadata_path")"

# Always start from a clean slate for generated outputs.
rm -rf "$apps_root"
rm -rf "$sources_root"
mkdir -p "$sources_root"
mkdir -p "$apps_root"
mkdir -p "$catalog_dir" "$metadata_dir"
rm -f "$catalog_path" "$metadata_path"

for source_id in "${source_ids[@]}"; do
  source_cfg="$(jq -c --arg id "$source_id" '.sources[] | select(.id == $id)' "$sources_file")"
  source_type="$(printf '%s' "$source_cfg" | jq -r '.type')"

  source_work_dir="$work_base/$source_id"
  mkdir -p "$source_work_dir"

  case "$source_type" in
    umbrel)
      log_info "Syncing source: $source_id"
      repo_dir="$($ROOT_DIR/scripts/sources/umbrel/fetch.sh "$ROOT_DIR" "$source_cfg" "$source_work_dir" | tail -n 1)"
      commit_sha="$(cat "$source_work_dir/source_commit.txt")"

      apps_list_file="$source_work_dir/apps.list"
      normalized_json="$source_work_dir/normalized.json"

      "$ROOT_DIR/scripts/sources/umbrel/discover.sh" "$repo_dir" "$apps_list_file"
      "$ROOT_DIR/scripts/sources/umbrel/normalize.sh" "$repo_dir" "$source_cfg" "$apps_list_file" "$commit_sha" "$normalized_json"
      "$ROOT_DIR/scripts/pipeline/write-repo.sh" "$ROOT_DIR" "$source_id" "$repo_dir" "$apps_list_file" "$normalized_json" "$commit_sha"
      ;;
    *)
      log_error "Unsupported source type: $source_type"
      exit 1
      ;;
  esac

done

gallery_work_dir="$work_base/gallery-assets"
mkdir -p "$gallery_work_dir"
"$ROOT_DIR/scripts/assets/umbrel-gallery/sync.sh" "$ROOT_DIR" "$gallery_work_dir"
bash "$ROOT_DIR/scripts/pipeline/enrich-assets.sh" "$ROOT_DIR"

merged_json="$work_base/merged.json"
mkdir -p "$ROOT_DIR/data"

"$ROOT_DIR/scripts/pipeline/merge-sources.sh" "$ROOT_DIR" "$merged_json"
"$ROOT_DIR/scripts/pipeline/build-catalog.sh" "$ROOT_DIR" "$merged_json" "$catalog_path" "$metadata_path"
"$ROOT_DIR/scripts/pipeline/validate.sh" "$ROOT_DIR"

log_info "Sync pipeline completed successfully"
