#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$1"
SOURCE_CONFIG_JSON="$2"
APPS_LIST_FILE="$3"
COMMIT_SHA="$4"
OUT_JSON="$5"

source_id="$(printf '%s' "$SOURCE_CONFIG_JSON" | jq -r '.id')"
repo_url="$(printf '%s' "$SOURCE_CONFIG_JSON" | jq -r '.repo_url')"
priority="$(printf '%s' "$SOURCE_CONFIG_JSON" | jq -r '.priority')"

yaml_scalar() {
  local key="$1"
  local file="$2"
  awk -v k="$key" '
    $0 ~ "^" k ":[[:space:]]*" {
      sub("^" k ":[[:space:]]*", "", $0)
      gsub(/^"|"$/, "", $0)
      gsub(/^\047|\047$/, "", $0)
      print $0
      exit
    }
  ' "$file"
}

yaml_text() {
  local key="$1"
  local file="$2"
  awk -v k="$key" '
    function trim_quotes(s) {
      gsub(/^"|"$/, "", s)
      gsub(/^\047|\047$/, "", s)
      return s
    }
    {
      if (!found && $0 ~ "^" k ":[[:space:]]*") {
        found=1
        line=$0
        sub("^" k ":[[:space:]]*", "", line)
        if (line ~ /^(\||>)/) {
          block=1
          next
        }
        print trim_quotes(line)
        exit
      }
      if (block) {
        if ($0 ~ /^[^[:space:]]/) {
          exit
        }
        sub(/^  /, "", $0)
        print $0
      }
    }
  ' "$file"
}

tmp_ndjson="$(mktemp)"

while IFS= read -r app_dir; do
  [[ -z "$app_dir" ]] && continue

  manifest="$app_dir/umbrel-app.yml"
  compose="$app_dir/docker-compose.yml"
  rel_path="${app_dir#"$REPO_DIR"/}"
  app_id="$(basename "$app_dir")"

  name="$(yaml_scalar name "$manifest")"
  version="$(yaml_scalar version "$manifest")"
  tagline="$(yaml_scalar tagline "$manifest")"
  description="$(yaml_text description "$manifest")"
  developer="$(yaml_scalar developer "$manifest")"
  category="$(yaml_scalar category "$manifest")"

  if [[ -z "$name" ]]; then
    name="$app_id"
  fi
  if [[ -z "$version" ]]; then
    version="unknown"
  fi
  if [[ -z "$description" ]]; then
    description="$tagline"
  fi

  jq -nc \
    --arg id "$app_id" \
    --arg name "$name" \
    --arg version "$version" \
    --arg tagline "$tagline" \
    --arg description "$description" \
    --arg developer "$developer" \
    --arg category "$category" \
    --arg source_id "$source_id" \
    --arg repo "$repo_url" \
    --arg commit "$COMMIT_SHA" \
    --arg path "$rel_path" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson priority "$priority" \
    --arg compose_rel "${compose#"$REPO_DIR"/}" \
    --arg manifest_rel "${manifest#"$REPO_DIR"/}" \
    '{
      id: $id,
      name: $name,
      version: $version,
      tagline: $tagline,
      description: $description,
      developer: $developer,
      repository_path: ("apps/" + $id),
      source: {
        id: $source_id,
        repo: $repo,
        commit: $commit,
        path: $path,
        priority: $priority
      },
      install: {
        method: "docker-compose",
        files: [$compose_rel, $manifest_rel]
      },
      search: {
        keywords: [$id, $name, $developer, $category] | map(select(length > 0)),
        categories: [$category] | map(select(length > 0))
      },
      updated_at: $updated_at
    }' >>"$tmp_ndjson"
done <"$APPS_LIST_FILE"

jq -s 'sort_by(.id)' "$tmp_ndjson" >"$OUT_JSON"
rm -f "$tmp_ndjson"
