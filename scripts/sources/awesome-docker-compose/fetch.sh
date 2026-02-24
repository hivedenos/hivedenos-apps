#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"
SOURCE_CONFIG_JSON="$2"
WORK_DIR="$3"

# shellcheck source=../../lib/log.sh
source "$ROOT_DIR/scripts/lib/log.sh"

out_dir="$WORK_DIR/repo"
rm -rf "$out_dir"
mkdir -p "$out_dir"

python3 "$ROOT_DIR/scripts/sources/awesome-docker-compose/extract.py" \
  --source-config-json "$SOURCE_CONFIG_JSON" \
  --out-dir "$out_dir" \
  --commit-file "$WORK_DIR/source_commit.txt"

commit_sha="$(cat "$WORK_DIR/source_commit.txt")"
log_info "Fetched Awesome Docker Compose source at $commit_sha"

printf '%s\n' "$out_dir"
