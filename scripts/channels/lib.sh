#!/usr/bin/env bash

init_channel_context() {
  local root_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

  CHANNELS_ROOT_DIR="$root_dir"
  CHANNELS_PIPELINE_FILE="$CHANNELS_ROOT_DIR/config/pipeline.json"
  CHANNELS_APPS_ROOT_REL="$(jq -r '.output.apps_root // "apps"' "$CHANNELS_PIPELINE_FILE")"
  CHANNELS_APPS_ROOT="$CHANNELS_ROOT_DIR/$CHANNELS_APPS_ROOT_REL"
}

validate_channel_name() {
  local channel_name="$1"
  local pipeline_file="${2:-$CHANNELS_PIPELINE_FILE}"

  if ! jq -e --arg channel_name "$channel_name" '.channels.definitions | has($channel_name)' "$pipeline_file" >/dev/null; then
    echo "Invalid channel: $channel_name" >&2
    echo "Allowed channels:" >&2
    jq -r '.channels.order[]' "$pipeline_file" >&2
    return 1
  fi
}

resolve_incubator_source_id() {
  local app_id="$1"
  local allow_none="${2:-false}"
  local apps_root="${3:-$CHANNELS_APPS_ROOT}"
  local matches

  mapfile -t matches < <(find "$apps_root/incubator" -mindepth 2 -maxdepth 2 -type d -name "$app_id" | sort)

  if [[ ${#matches[@]} -eq 0 ]]; then
    if [[ "$allow_none" == "true" ]]; then
      printf '\n'
      return 0
    fi
    echo "No incubator app directory found for app: $app_id" >&2
    return 1
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    echo "Multiple incubator app directories found for app: $app_id" >&2
    echo "Please provide [source-id] explicitly." >&2
    printf '%s\n' "${matches[@]#$apps_root/}" >&2
    return 1
  fi

  basename "$(dirname "${matches[0]}")"
}

channel_app_rel_path() {
  local channel_name="$1"
  local app_id="$2"
  local source_id="$3"
  local apps_root_rel="${4:-$CHANNELS_APPS_ROOT_REL}"

  if [[ "$channel_name" == "incubator" ]]; then
    if [[ -z "$source_id" || "$source_id" == "*" ]]; then
      echo "A concrete source-id is required for incubator channel paths." >&2
      return 1
    fi
    printf '%s/incubator/%s/%s\n' "$apps_root_rel" "$source_id" "$app_id"
  else
    printf '%s/%s/%s\n' "$apps_root_rel" "$channel_name" "$app_id"
  fi
}

channel_source_root_abs_path() {
  local root_dir="$1"
  local channel_name="$2"
  local source_id="$3"
  local apps_root_rel="${4:-$CHANNELS_APPS_ROOT_REL}"

  if [[ "$channel_name" != "incubator" ]]; then
    printf '\n'
    return 0
  fi

  if [[ -z "$source_id" || "$source_id" == "*" ]]; then
    echo "A concrete source-id is required for incubator source root paths." >&2
    return 1
  fi

  printf '%s/%s/incubator/%s\n' "$root_dir" "$apps_root_rel" "$source_id"
}

remove_empty_incubator_source_root() {
  local source_root="$1"

  if [[ -z "$source_root" || ! -d "$source_root" ]]; then
    return 0
  fi

  if [[ -z "$(find "$source_root" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]]; then
    rmdir "$source_root"
  fi
}

rewrite_branding_to_hiveden() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  perl -0pi -e '
    s/umbrelOS/hivedenOS/g;
    s/UmbrelOS/HivedenOS/g;
    s/Umbrel App Store/Hiveden App Store/g;
    s/umbrel app store/hiveden app store/g;
    s/umbrel\.local/hiveden.local/g;
    s/Umbrel/Hiveden/g;
    s/umbrel/hiveden/g;
  ' "$file"
}

customize_app_dir_for_hiveden() {
  local app_dir="$1"
  local file

  rewrite_branding_to_hiveden "$app_dir/umbrel-app.yml"

  while IFS= read -r file; do
    rewrite_branding_to_hiveden "$file"
  done < <(find "$app_dir" -mindepth 1 -maxdepth 1 -type f \( -iname '*.md' -o -iname '*.txt' \) | sort)
}

normalize_app_image_dir() {
  local app_dir="$1"
  local img_dir="$app_dir/img"
  local legacy_imgs_dir="$app_dir/imgs"
  local legacy_file
  local base_name

  if [[ ! -d "$legacy_imgs_dir" ]]; then
    return 0
  fi

  if [[ -d "$img_dir" ]]; then
    while IFS= read -r legacy_file; do
      base_name="$(basename "$legacy_file")"
      if [[ ! -e "$img_dir/$base_name" ]]; then
        mv "$legacy_file" "$img_dir/$base_name"
      fi
    done < <(find "$legacy_imgs_dir" -mindepth 1 -maxdepth 1 -type f | sort)
    rm -rf "$legacy_imgs_dir"
  else
    mv "$legacy_imgs_dir" "$img_dir"
  fi
}
