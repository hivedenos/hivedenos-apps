#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"
WORK_DIR="$2"

# shellcheck source=../../lib/log.sh
source "$ROOT_DIR/scripts/lib/log.sh"
# shellcheck source=../../lib/git.sh
source "$ROOT_DIR/scripts/lib/git.sh"

gallery_enabled="$(jq -r '.assets.gallery.enabled // false' "$ROOT_DIR/config/pipeline.json")"
if [[ "$gallery_enabled" != "true" ]]; then
  log_info "Umbrel gallery sync is disabled"
  exit 0
fi

gallery_repo_url="$(jq -r '.assets.gallery.repo_url' "$ROOT_DIR/config/pipeline.json")"
gallery_branch="$(jq -r '.assets.gallery.branch // "master"' "$ROOT_DIR/config/pipeline.json")"
apps_root_rel="$(jq -r '.output.apps_root // "apps"' "$ROOT_DIR/config/pipeline.json")"
apps_root="$ROOT_DIR/$apps_root_rel"

if [[ ! -d "$apps_root" ]]; then
  log_warn "Apps root not found: $apps_root"
  exit 0
fi

gallery_repo_dir="$WORK_DIR/umbrel-gallery"
git_clone_branch "$gallery_repo_url" "$gallery_branch" "$gallery_repo_dir" >/dev/null
log_info "Fetched Umbrel gallery source"

is_image_file() {
  local file="$1"
  case "${file##*.}" in
    jpg|JPG|jpeg|JPEG|png|PNG|webp|WEBP|gif|GIF|svg|SVG)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

first_existing_dir() {
  local candidate
  for candidate in "$@"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

emit_app_dirs() {
  local channel_dir
  local source_dir
  local app_dir

  for channel_dir in "$apps_root"/*; do
    [[ -d "$channel_dir" ]] || continue

    if [[ "$(basename "$channel_dir")" == "incubator" ]]; then
      for source_dir in "$channel_dir"/*; do
        [[ -d "$source_dir" ]] || continue
        for app_dir in "$source_dir"/*; do
          [[ -d "$app_dir" ]] || continue
          printf '%s\n' "$app_dir"
        done
      done
    else
      for app_dir in "$channel_dir"/*; do
        [[ -d "$app_dir" ]] || continue
        printf '%s\n' "$app_dir"
      done
    fi
  done
}

while IFS= read -r app_dir; do
  [[ -d "$app_dir" ]] || continue

  app_id="$(basename "$app_dir")"
  gallery_app_dir=""

  if ! gallery_app_dir="$(first_existing_dir \
    "$gallery_repo_dir/$app_id" \
    "$gallery_repo_dir/apps/$app_id")"; then
    gallery_app_dir="$(find "$gallery_repo_dir" -mindepth 1 -maxdepth 4 -type d -name "$app_id" | head -n 1 || true)"
    if [[ -z "$gallery_app_dir" ]]; then
      continue
    fi
  fi

  src_assets_dir=""
  src_assets_dir="$(first_existing_dir \
    "$gallery_app_dir" \
    "$gallery_app_dir/imgs" \
    "$gallery_app_dir/images" \
    "$gallery_app_dir/screenshots")"

  img_dir="$app_dir/img"
  rm -rf "$img_dir" "$app_dir/imgs"
  mkdir -p "$img_dir"

  icon_src=""
  while IFS= read -r icon_candidate; do
    icon_src="$icon_candidate"
    break
  done < <(find "$src_assets_dir" -maxdepth 1 -type f \( -iname 'icon.svg' -o -iname 'icon.png' -o -iname 'icon.jpg' -o -iname 'icon.jpeg' -o -iname 'icon.webp' \) | sort)

  if [[ -n "$icon_src" ]]; then
    icon_ext="${icon_src##*.}"
    icon_ext="$(printf '%s' "$icon_ext" | tr '[:upper:]' '[:lower:]')"
    cp "$icon_src" "$img_dir/icon.$icon_ext"
  fi

  screenshot_index=1
  while IFS= read -r image_file; do
    base_name="$(basename "$image_file")"
    if [[ "$base_name" =~ ^icon\.[a-zA-Z0-9]+$ ]]; then
      continue
    fi
    if ! is_image_file "$image_file"; then
      continue
    fi

    ext="${image_file##*.}"
    ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ext" == "jpeg" ]]; then
      ext="jpg"
    fi

    cp "$image_file" "$img_dir/$screenshot_index.$ext"
    screenshot_index=$((screenshot_index + 1))
  done < <(find "$src_assets_dir" -maxdepth 1 -type f | sort)

  # Remove empty img directory when no icon/screenshots are available.
  if [[ -z "$(find "$img_dir" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]]; then
    rmdir "$img_dir"
  fi

done < <(emit_app_dirs)
