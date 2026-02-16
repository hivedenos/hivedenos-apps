#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"
OUT_JSON="$2"

mapfile -t normalized_files < <(find "$ROOT_DIR/data/sources" -mindepth 2 -maxdepth 2 -type f -name 'normalized.json' | sort)

if [[ ${#normalized_files[@]} -eq 0 ]]; then
  echo '[]' >"$OUT_JSON"
  exit 0
fi

jq -s \
  --argjson priorities "$(jq '.sources | map({(.id): .priority}) | add' "$ROOT_DIR/config/sources.json")" \
  '
  [ .[] | .[] ]
  | sort_by(($priorities[.source.id] // 999999), .id)
  | reduce .[] as $app ([]; if any(.[]; .id == $app.id) then . else . + [$app] end)
  | sort_by(.id)
  ' "${normalized_files[@]}" >"$OUT_JSON"
