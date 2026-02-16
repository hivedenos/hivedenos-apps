#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"

sources_file="$ROOT_DIR/config/sources.json"
catalog_file="$ROOT_DIR/data/apps.json"
apps_root_rel="$(jq -r '.output.apps_root // "apps"' "$ROOT_DIR/config/pipeline.json")"

jq -e '.sources and (.sources | type == "array")' "$sources_file" >/dev/null
jq -e '.sources | all(.[]; has("id") and has("enabled") and has("type") and has("repo_url") and has("branch") and has("priority"))' "$sources_file" >/dev/null

if [[ ! -f "$catalog_file" ]]; then
  echo "Catalog file missing: $catalog_file" >&2
  exit 1
fi

jq -e 'has("version") and has("generated_at") and has("total_apps") and has("apps")' "$catalog_file" >/dev/null
jq -e '.apps | type == "array"' "$catalog_file" >/dev/null
jq -e '(.apps | length) == .total_apps' "$catalog_file" >/dev/null
jq -e '.apps | all(.[]; has("id") and has("name") and has("version") and has("tagline") and has("description") and has("repository_path") and has("icon_url") and has("image_urls") and has("source") and has("install") and has("search") and has("updated_at"))' "$catalog_file" >/dev/null
jq -e '.apps | all(.[]; (.install.files | type == "array" and length > 0))' "$catalog_file" >/dev/null
jq -e '.apps | all(.[]; (.image_urls | type == "array"))' "$catalog_file" >/dev/null
jq -e --arg apps_root "$apps_root_rel/" '.apps | all(.[]; (.repository_path | startswith($apps_root)))' "$catalog_file" >/dev/null

# IDs must be unique.
app_count="$(jq '.apps | length' "$catalog_file")"
unique_count="$(jq '[.apps[].id] | unique | length' "$catalog_file")"
if [[ "$app_count" != "$unique_count" ]]; then
  echo "Duplicate app IDs detected in catalog" >&2
  exit 1
fi

while IFS= read -r app_path; do
  if [[ ! -d "$ROOT_DIR/$app_path" ]]; then
    echo "Missing app directory: $app_path" >&2
    exit 1
  fi
done < <(jq -r '.apps[].repository_path' "$catalog_file")

while IFS= read -r icon_path; do
  [[ "$icon_path" == "null" ]] && continue
  if [[ ! -f "$ROOT_DIR/$icon_path" ]]; then
    echo "Missing icon file: $icon_path" >&2
    exit 1
  fi
done < <(jq -r '.apps[].icon_url' "$catalog_file")

while IFS= read -r image_path; do
  if [[ ! -f "$ROOT_DIR/$image_path" ]]; then
    echo "Missing image file: $image_path" >&2
    exit 1
  fi
done < <(jq -r '.apps[].image_urls[]' "$catalog_file")
