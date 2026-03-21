#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"
SOURCE_CONFIG_JSON="$2"
WORK_DIR="$3"

# shellcheck source=../../lib/git.sh
source "$ROOT_DIR/scripts/lib/git.sh"
# shellcheck source=../../lib/log.sh
source "$ROOT_DIR/scripts/lib/log.sh"

repo_url="$(printf '%s' "$SOURCE_CONFIG_JSON" | jq -r '.repo_url')"
branch="$(printf '%s' "$SOURCE_CONFIG_JSON" | jq -r '.branch')"
out_dir="$WORK_DIR/repo"

err_file="$(mktemp)"
cleanup() {
  rm -f "$err_file"
}
trap cleanup EXIT

if ! git_clone_branch "$repo_url" "$branch" "$out_dir" 2>"$err_file"; then
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
  log_error "Failed to fetch Umbrel source: $failure_reason"
  exit 1
fi

commit_sha="$(git_head_sha "$out_dir")"

log_info "Fetched Umbrel source at $commit_sha"
printf '%s\n' "$out_dir"
printf '%s\n' "$commit_sha" >"$WORK_DIR/source_commit.txt"

trap - EXIT
cleanup
