#!/usr/bin/env bash

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not installed" >&2
    exit 1
  fi
}

json_get() {
  local file="$1"
  local query="$2"
  jq -r "$query" "$file"
}

json_get_compact() {
  local file="$1"
  local query="$2"
  jq -c "$query" "$file"
}
