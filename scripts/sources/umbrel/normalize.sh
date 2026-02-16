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

normalize_image_name() {
  local image="$1"
  image="${image#\"}"
  image="${image%\"}"
  image="${image#\'}"
  image="${image%\'}"
  image="${image%%@*}"
  image="${image%%:*}"
  image="${image##*/}"
  printf '%s\n' "$image"
}

compose_service_images_json() {
  local compose_file="$1"
  local tmp_map
  tmp_map="$(mktemp)"

  awk '
    BEGIN { in_services=0; service="" }
    /^services:[[:space:]]*$/ { in_services=1; next }
    in_services && /^[^[:space:]]/ { in_services=0; service=""; next }
    !in_services { next }

    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      service=$0
      sub(/^  /, "", service)
      sub(/:[[:space:]]*$/, "", service)
      next
    }

    service != "" && /^    image:[[:space:]]*/ {
      img=$0
      sub(/^    image:[[:space:]]*/, "", img)
      sub(/[[:space:]]+#.*/, "", img)
      print service "\t" img
    }
  ' "$compose_file" >"$tmp_map"

  {
    while IFS=$'\t' read -r service image; do
      [[ -z "$service" || -z "$image" ]] && continue
      normalized_image="$(normalize_image_name "$image")"
      [[ -z "$normalized_image" ]] && continue
      printf '{"service":"%s","image":"%s"}\n' "$service" "$normalized_image"
    done <"$tmp_map"
  } | jq -cs 'map({(.service): .image}) | add // {}'

  rm -f "$tmp_map"
}

compose_dep_services_json() {
  local compose_file="$1"
  awk '
    BEGIN { in_services=0; service=""; in_dep=0 }
    /^services:[[:space:]]*$/ { in_services=1; next }
    in_services && /^[^[:space:]]/ { in_services=0; service=""; in_dep=0; next }
    !in_services { next }

    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      service=$0
      sub(/^  /, "", service)
      sub(/:[[:space:]]*$/, "", service)
      in_dep=0
      next
    }

    service != "" && /^    depends_on:[[:space:]]*$/ {
      in_dep=1
      next
    }

    in_dep && /^    [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      in_dep=0
      next
    }

    in_dep && /^      - [A-Za-z0-9_.-]+[[:space:]]*$/ {
      dep=$0
      sub(/^      - /, "", dep)
      sub(/[[:space:]]*$/, "", dep)
      print dep
      next
    }

    in_dep && /^      [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      dep=$0
      sub(/^      /, "", dep)
      sub(/:[[:space:]]*$/, "", dep)
      print dep
      next
    }

    in_dep && !/^      / {
      in_dep=0
    }
  ' "$compose_file" | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))'
}

compose_resolved_dependencies_json() {
  local compose_file="$1"
  local dep_services_json
  local service_images_json
  dep_services_json="$(compose_dep_services_json "$compose_file")"
  service_images_json="$(compose_service_images_json "$compose_file")"

  jq -n \
    --argjson deps "$dep_services_json" \
    --argjson images "$service_images_json" \
    '$deps
      | map((. as $dep | ($images[$dep] // $dep)))
      | map(select(length > 0))
      | unique
      | sort'
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
  dependencies_json="$(compose_resolved_dependencies_json "$compose")"

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
    --argjson dependencies "$dependencies_json" \
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
      dependencies: $dependencies,
      updated_at: $updated_at
    }' >>"$tmp_ndjson"
done <"$APPS_LIST_FILE"

jq -s 'sort_by(.id)' "$tmp_ndjson" >"$OUT_JSON"
rm -f "$tmp_ndjson"
