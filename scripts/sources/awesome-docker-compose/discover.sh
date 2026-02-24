#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$1"
OUT_FILE="$2"

find "$REPO_DIR" -mindepth 1 -maxdepth 1 -type d \
  | while read -r app_dir; do
      if [[ -f "$app_dir/docker-compose.yml" && ( -f "$app_dir/hiveden-app.yml" || -f "$app_dir/hiveden-app.yaml" ) ]]; then
        printf '%s\n' "$app_dir"
      fi
    done \
  | sort -u >"$OUT_FILE"
