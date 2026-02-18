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
    target_rel="${target_rel}--$SOURCE_ID"
    target_abs="$ROOT_DIR/$target_rel"
  fi

  rm -rf "$target_abs"
  mkdir -p "$target_abs"
  rsync -a --delete "$app_dir/" "$target_abs/"

  jq -nc --arg id "$app_name" --arg repository_path "$target_rel" \
    '{id: $id, repository_path: $repository_path}' >>"$mapping_ndjson"
done <"$APPS_LIST_FILE"

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
