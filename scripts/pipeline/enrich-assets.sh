#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"

apps_root_rel="$(jq -r '.output.apps_root // "apps"' "$ROOT_DIR/config/pipeline.json")"
apps_root="$ROOT_DIR/$apps_root_rel"

mapfile -t normalized_files < <(find "$ROOT_DIR/data/sources" -mindepth 2 -maxdepth 2 -type f -name 'normalized.json' | sort)

if [[ ${#normalized_files[@]} -eq 0 ]]; then
  exit 0
fi

for normalized_file in "${normalized_files[@]}"; do
  tmp_ndjson="$(mktemp)"

  while IFS= read -r app_json; do
    app_id="$(printf '%s' "$app_json" | jq -r '.id')"
    repository_path="$(printf '%s' "$app_json" | jq -r '.repository_path // empty')"
    if [[ -z "$repository_path" ]]; then
      repository_path="$apps_root_rel/$app_id"
    fi

    img_dir="$ROOT_DIR/$repository_path/img"
    legacy_imgs_dir="$ROOT_DIR/$repository_path/imgs"
    assets_dir=""
    assets_rel=""
    icon_url='null'
    image_urls='[]'

    if [[ -d "$img_dir" ]]; then
      assets_dir="$img_dir"
      assets_rel="img"
    elif [[ -d "$legacy_imgs_dir" ]]; then
      assets_dir="$legacy_imgs_dir"
      assets_rel="imgs"
    fi

    if [[ -n "$assets_dir" ]]; then
      icon_file="$(find "$assets_dir" -maxdepth 1 -type f \( -iname 'icon.svg' -o -iname 'icon.png' -o -iname 'icon.jpg' -o -iname 'icon.jpeg' -o -iname 'icon.webp' \) | sort | head -n 1 || true)"
      if [[ -n "$icon_file" ]]; then
        icon_url="${repository_path}/${assets_rel}/$(basename "$icon_file")"
      fi

      image_urls="$(find "$assets_dir" -maxdepth 1 -type f | sort | while IFS= read -r img; do
        base="$(basename "$img")"
        if [[ "$base" =~ ^icon\.[a-zA-Z0-9]+$ ]]; then
          continue
        fi
        printf '%s\n' "${repository_path}/${assets_rel}/${base}"
      done | jq -Rsc 'split("\n") | map(select(length > 0))')"
    fi

    if [[ "$icon_url" == "null" ]]; then
      printf '%s' "$app_json" | jq -c --argjson image_urls "$image_urls" '. + {icon_url: null, image_urls: $image_urls}' >>"$tmp_ndjson"
    else
      printf '%s' "$app_json" | jq -c --arg icon_url "$icon_url" --argjson image_urls "$image_urls" '. + {icon_url: $icon_url, image_urls: $image_urls}' >>"$tmp_ndjson"
    fi
  done < <(jq -c '.[]' "$normalized_file")

  jq -s 'sort_by(.id)' "$tmp_ndjson" >"$normalized_file"
  rm -f "$tmp_ndjson"
done
