#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$1"
OUT_FILE="$2"

# Umbrel apps are directories with docker-compose.yml and umbrel-app.yml
find "$REPO_DIR" -mindepth 1 -maxdepth 2 -type f -name 'docker-compose.yml' \
  | while read -r compose_file; do
      app_dir="$(dirname "$compose_file")"
      if [[ -f "$app_dir/umbrel-app.yml" ]]; then
        printf '%s\n' "$app_dir"
      fi
    done \
  | sort -u >"$OUT_FILE"
