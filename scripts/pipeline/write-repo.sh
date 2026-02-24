#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"
SOURCE_ID="$2"
REPO_DIR="$3"
APPS_LIST_FILE="$4"
NORMALIZED_JSON="$5"
COMMIT_SHA="$6"

source_dir="$ROOT_DIR/data/sources/$SOURCE_ID"
apps_out="$source_dir/apps"
apps_root_rel="$(jq -r '.output.apps_root // "apps"' "$ROOT_DIR/config/pipeline.json")"
apps_root="$ROOT_DIR/$apps_root_rel"
mkdir -p "$apps_out"
mkdir -p "$apps_root"

# Replace source mirror atomically.
rm -rf "$apps_out"
mkdir -p "$apps_out"

mapping_ndjson="$(mktemp)"
declare -A planned_targets=()

source_marker_filename=".hivedenos-source-id"

target_has_source_marker() {
  local dir="$1"
  local expected_source="$2"
  local marker_file="$dir/$source_marker_filename"

  [[ -f "$marker_file" ]] || return 1

  local marker_value
  marker_value="$(tr -d '\r\n' <"$marker_file")"
  [[ "$marker_value" == "$expected_source" ]]
}

while IFS= read -r app_dir; do
  [[ -z "$app_dir" ]] && continue
  app_name="$(basename "$app_dir")"
  app_channel="$(jq -r --arg id "$app_name" '.[] | select(.id == $id) | .channel // "incubator"' "$NORMALIZED_JSON" | head -n 1)"
  if [[ -z "$app_channel" || "$app_channel" == "null" ]]; then
    app_channel="incubator"
  fi

  rsync -a --delete "$app_dir/" "$apps_out/$app_name/"

  if [[ "$app_channel" == "incubator" ]]; then
    target_rel="$apps_root_rel/incubator/$SOURCE_ID/$app_name"
  else
    target_rel="$apps_root_rel/$app_channel/$app_name"
  fi
  target_abs="$ROOT_DIR/$target_rel"
  if [[ -e "$target_abs" ]]; then
    if target_has_source_marker "$target_abs" "$SOURCE_ID"; then
      :
    else
      candidate_rel="${target_rel}--$SOURCE_ID"
      candidate_abs="$ROOT_DIR/$candidate_rel"

      if [[ -e "$candidate_abs" ]] && target_has_source_marker "$candidate_abs" "$SOURCE_ID"; then
        target_rel="$candidate_rel"
        target_abs="$candidate_abs"
      elif [[ -e "$candidate_abs" ]]; then
        suffix_index=2
        while [[ -e "$ROOT_DIR/${candidate_rel}-${suffix_index}" ]]; do
          suffix_index=$((suffix_index + 1))
        done
        target_rel="${candidate_rel}-${suffix_index}"
        target_abs="$ROOT_DIR/$target_rel"
      else
        target_rel="$candidate_rel"
        target_abs="$candidate_abs"
      fi
    fi
  fi

  rm -rf "$target_abs"
  mkdir -p "$target_abs"
  rsync -a --delete "$app_dir/" "$target_abs/"
  printf '%s\n' "$SOURCE_ID" >"$target_abs/$source_marker_filename"
  planned_targets["$target_abs"]=1

  jq -nc --arg id "$app_name" --arg repository_path "$target_rel" \
    '{id: $id, repository_path: $repository_path}' >>"$mapping_ndjson"
done <"$APPS_LIST_FILE"

# Prune stale app placements for this source when channel or naming changes.
while IFS= read -r marker_file; do
  app_dir="$(dirname "$marker_file")"
  marker_value="$(tr -d '\r\n' <"$marker_file")"
  [[ "$marker_value" == "$SOURCE_ID" ]] || continue

  if [[ -n "${planned_targets[$app_dir]+x}" ]]; then
    continue
  fi

  rm -rf "$app_dir"
done < <(find "$apps_root" -type f -name "$source_marker_filename" 2>/dev/null)

mapping_obj="$(jq -s 'map({(.id): .repository_path}) | add // {}' "$mapping_ndjson")"
jq --argjson path_map "$mapping_obj" \
  'map(. + {repository_path: ($path_map[.id] // .repository_path // ("apps/" + .id))})' \
  "$NORMALIZED_JSON" >"$source_dir/normalized.json"
rm -f "$mapping_ndjson"

app_count="$(jq 'length' "$NORMALIZED_JSON")"
source_repo_url="$(jq -r --arg id "$SOURCE_ID" '.sources[] | select(.id == $id) | .repo_url' "$ROOT_DIR/config/sources.json")"

jq -n \
  --arg id "$SOURCE_ID" \
  --arg commit "$COMMIT_SHA" \
  --arg repo "$source_repo_url" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson total_apps "$app_count" \
  '{
    id: $id,
    repo: $repo,
    commit: $commit,
    total_apps: $total_apps,
    generated_at: $generated_at
  }' >"$source_dir/metadata.json"
