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

err_file="$(mktemp)"
cleanup() {
  rm -f "$err_file"
}
trap cleanup EXIT

if ! python3 "$ROOT_DIR/scripts/sources/awesome-docker-compose/extract.py" \
  --source-config-json "$SOURCE_CONFIG_JSON" \
  --out-dir "$out_dir" \
  --commit-file "$WORK_DIR/source_commit.txt" \
  2>"$err_file"; then
  failure_reason="$(python3 - "$err_file" <<'PY'
import sys
from pathlib import Path

lines = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
message = lines[-1] if lines else "unknown error"
if message.startswith("[ERROR] "):
    message = message[len("[ERROR] "):]
print(message)
PY
)"
  log_error "Failed to fetch Awesome Docker Compose source: $failure_reason"
  exit 1
fi

commit_sha="$(cat "$WORK_DIR/source_commit.txt")"
log_info "Fetched Awesome Docker Compose source at $commit_sha"

printf '%s\n' "$out_dir"

trap - EXIT
cleanup
