#!/usr/bin/env bash

clean_dir() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
}

git_clone_branch() {
  local repo_url="$1"
  local branch="$2"
  local out_dir="$3"

  rm -rf "$out_dir"
  git clone --depth 1 --branch "$branch" "$repo_url" "$out_dir"
}

git_head_sha() {
  local repo_dir="$1"
  git -C "$repo_dir" rev-parse HEAD
}
