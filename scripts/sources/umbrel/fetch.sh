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

git_clone_branch "$repo_url" "$branch" "$out_dir"
commit_sha="$(git_head_sha "$out_dir")"

log_info "Fetched Umbrel source at $commit_sha"
printf '%s\n' "$out_dir"
printf '%s\n' "$commit_sha" >"$WORK_DIR/source_commit.txt"
