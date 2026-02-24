#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/channels/lib.sh"
init_channel_context "$ROOT_DIR"

pipeline_file="$CHANNELS_PIPELINE_FILE"
apps_root_rel="$CHANNELS_APPS_ROOT_REL"

usage() {
  echo "Usage: $0 <app-id> <channel> [source-id]" >&2
  echo "Example: $0 my-app beta" >&2
  echo "Example: $0 my-app incubator custom-source" >&2
}

prompt_text() {
  local label="$1"
  local default_value="${2:-}"
  local value

  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " value
    value="${value:-$default_value}"
  else
    read -r -p "$label: " value
  fi
  printf '%s\n' "$value"
}

prompt_required() {
  local label="$1"
  local default_value="${2:-}"
  local value

  while true; do
    value="$(prompt_text "$label" "$default_value")"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    echo "This field is required." >&2
  done
}

prompt_bool() {
  local label="$1"
  local default_value="$2"
  local value

  while true; do
    value="$(prompt_text "$label (true/false)" "$default_value")"
    case "$value" in
      true|false)
        printf '%s\n' "$value"
        return 0
        ;;
      *)
        echo "Please answer true or false." >&2
        ;;
    esac
  done
}

yaml_quote() {
  local value="$1"
  value="${value//\'/\'\"\'\"\'}"
  printf "'%s'" "$value"
}

validate_slug() {
  local value="$1"
  if [[ ! "$value" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "Invalid app id: $value" >&2
    echo "Allowed: lowercase letters, numbers, hyphens; must start with letter/number." >&2
    exit 1
  fi
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 1
fi

app_id="$1"
channel="$2"
source_id="${3:-*}"

if [[ -z "$app_id" || -z "$channel" ]]; then
  usage
  exit 1
fi

validate_slug "$app_id"
validate_channel_name "$channel" "$pipeline_file"

resolved_source_id="$source_id"
if [[ "$channel" == "incubator" && "$resolved_source_id" == "*" ]]; then
  resolved_source_id="$(prompt_required "Source id for incubator app" "custom-source")"
fi

app_rel="$(channel_app_rel_path "$channel" "$app_id" "$resolved_source_id" "$apps_root_rel")"
app_abs="$ROOT_DIR/$app_rel"

if [[ -e "$app_abs" ]]; then
  echo "App directory already exists: $app_rel" >&2
  exit 1
fi

echo "Creating app in: $app_rel"
echo "Please answer a few questions to generate hiveden-app.yml"

name="$(prompt_required "Display name")"
version="$(prompt_required "Version" "0.1.0")"
category="$(prompt_required "Category" "utilities")"
tagline="$(prompt_required "Tagline")"
description="$(prompt_required "Description")"
developer="$(prompt_required "Developer" "Hiveden")"
website="$(prompt_text "Website URL (optional)")"
repo_url="$(prompt_text "Repository URL (optional)")"
support_url="$(prompt_text "Support URL (optional)")"
service_name="$(prompt_required "Docker service name" "app")"
image_ref="$(prompt_required "Docker image" "ghcr.io/example/app:latest")"
port="$(prompt_text "App port (optional)")"
path="$(prompt_text "App path (optional)" "/")"
default_username="$(prompt_text "Default username (optional)")"
deterministic_password="$(prompt_bool "Deterministic password" "true")"
tor_only="$(prompt_bool "Tor only" "false")"

if [[ -n "$port" && ! "$port" =~ ^[0-9]+$ ]]; then
  echo "Port must be numeric when provided." >&2
  exit 1
fi

mkdir -p "$app_abs/img"

compose_file="$app_abs/docker-compose.yml"
manifest_file="$app_abs/hiveden-app.yml"

cat >"$compose_file" <<EOF
version: "3.8"

services:
  $service_name:
    image: $image_ref
    restart: unless-stopped
    volumes:
      - \${APP_DATA_DIR}/data:/data
EOF

if [[ -n "$port" ]]; then
  cat >>"$compose_file" <<EOF
    ports:
      - "$port:$port"
EOF
fi

{
  printf 'manifestVersion: 1.1\n'
  printf 'id: %s\n' "$app_id"
  printf 'category: %s\n' "$category"
  printf 'name: %s\n' "$(yaml_quote "$name")"
  printf 'version: %s\n' "$(yaml_quote "$version")"
  printf 'tagline: %s\n' "$(yaml_quote "$tagline")"
  printf 'description: %s\n' "$(yaml_quote "$description")"
  printf 'developer: %s\n' "$(yaml_quote "$developer")"
  if [[ -n "$website" ]]; then
    printf 'website: %s\n' "$(yaml_quote "$website")"
  fi
  printf 'dependencies: []\n'
  if [[ -n "$repo_url" ]]; then
    printf 'repo: %s\n' "$(yaml_quote "$repo_url")"
  fi
  if [[ -n "$support_url" ]]; then
    printf 'support: %s\n' "$(yaml_quote "$support_url")"
  fi
  if [[ -n "$port" ]]; then
    printf 'port: %s\n' "$port"
  fi
  printf 'gallery: []\n'
  printf 'path: %s\n' "$(yaml_quote "$path")"
  printf 'defaultUsername: %s\n' "$(yaml_quote "$default_username")"
  printf 'deterministicPassword: %s\n' "$deterministic_password"
  printf 'torOnly: %s\n' "$tor_only"
  printf 'submitter: %s\n' "$(yaml_quote "Hiveden")"
} >"$manifest_file"

touch "$app_abs/img/.gitkeep"

if [[ ! -f "$compose_file" || ! -f "$manifest_file" || ! -d "$app_abs/img" ]]; then
  echo "Failed to create required app files in: $app_rel" >&2
  exit 1
fi

for required_key in id name version tagline description; do
  if ! grep -Eq "^${required_key}:" "$manifest_file"; then
    echo "Missing required key '$required_key' in $manifest_file" >&2
    exit 1
  fi
done

bash "$ROOT_DIR/scripts/channels/rebuild-catalog.sh" "$ROOT_DIR"

echo "Created app scaffold: $app_rel"
echo "Created files:"
echo "- $app_rel/docker-compose.yml"
echo "- $app_rel/hiveden-app.yml"
echo "- $app_rel/img/.gitkeep"
echo "Updated catalog outputs: data/apps.json and data/metadata.json"
