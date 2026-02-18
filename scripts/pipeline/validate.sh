#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"

sources_file="$ROOT_DIR/config/sources.json"
channel_overrides_file="$ROOT_DIR/config/channel-overrides.json"
pipeline_file="$ROOT_DIR/config/pipeline.json"
catalog_file="$ROOT_DIR/data/apps.json"
apps_root_rel="$(jq -r '.output.apps_root // "apps"' "$pipeline_file")"

channel_defs_json="$(jq -c '.channels.definitions // {}' "$pipeline_file")"
channel_order_json="$(jq -c '.channels.order // ["stable", "beta", "edge", "incubator"]' "$pipeline_file")"
default_channel="$(jq -r '.channels.default // "stable"' "$pipeline_file")"
ingest_source_channel="$(jq -r '.channels.ingest_source_channel // "incubator"' "$pipeline_file")"

jq -e --arg ingest_source_channel "$ingest_source_channel" --argjson channel_defs "$channel_defs_json" '$channel_defs | has($ingest_source_channel)' "$pipeline_file" >/dev/null

jq -e '.sources and (.sources | type == "array")' "$sources_file" >/dev/null
jq -e '.sources | all(.[]; has("id") and has("enabled") and has("type") and has("channel") and has("repo_url") and has("branch") and has("priority"))' "$sources_file" >/dev/null
jq -e --argjson channel_defs "$channel_defs_json" '.sources | all(.[]; (.channel as $channel | ($channel_defs | has($channel))))' "$sources_file" >/dev/null

if [[ ! -f "$channel_overrides_file" ]]; then
  echo "Channel override file missing: $channel_overrides_file" >&2
  exit 1
fi

jq -e 'has("version") and has("overrides") and (.overrides | type == "array")' "$channel_overrides_file" >/dev/null
jq -e --argjson channel_defs "$channel_defs_json" '.overrides | all(.[]; has("id") and has("channel") and (.channel as $channel | ($channel_defs | has($channel))))' "$channel_overrides_file" >/dev/null

if [[ ! -f "$catalog_file" ]]; then
  echo "Catalog file missing: $catalog_file" >&2
  exit 1
fi

jq -e 'has("version") and has("generated_at") and has("default_channel") and has("total_apps") and has("total_apps_all_channels") and has("channels") and has("apps") and has("apps_by_channel")' "$catalog_file" >/dev/null
jq -e '.channels | type == "object"' "$catalog_file" >/dev/null
jq -e '.apps | type == "array"' "$catalog_file" >/dev/null
jq -e '.apps_by_channel | type == "object"' "$catalog_file" >/dev/null
jq -e --arg default_channel "$default_channel" '.default_channel == $default_channel' "$catalog_file" >/dev/null
jq -e --argjson channel_order "$channel_order_json" '.apps_by_channel | (keys | sort) == ($channel_order | sort)' "$catalog_file" >/dev/null
jq -e --argjson channel_order "$channel_order_json" '.channels | (keys | sort) == ($channel_order | sort)' "$catalog_file" >/dev/null
jq -e '.apps == (.apps_by_channel[.default_channel] // [])' "$catalog_file" >/dev/null
jq -e '.total_apps == (.apps | length)' "$catalog_file" >/dev/null
jq -e '.total_apps_all_channels == ([.apps_by_channel[] | .[]] | length)' "$catalog_file" >/dev/null
jq -e '.channels | to_entries | all(.[]; has("key") and (.value | has("total_apps") and has("warning")))' "$catalog_file" >/dev/null
jq -e '.channels as $channels | .apps_by_channel | to_entries | all(.[]; ($channels[.key].total_apps == (.value | length)))' "$catalog_file" >/dev/null
jq -e '.apps_by_channel | to_entries | all(.[]; (.key as $channel | (.value | all(.[]; .channel == $channel))))' "$catalog_file" >/dev/null

jq -e --argjson channel_defs "$channel_defs_json" '
  [.apps_by_channel[] | .[]]
  | all(.[];
      has("id")
      and has("name")
      and has("version")
      and has("tagline")
      and has("description")
      and has("channel")
      and has("channel_label")
      and has("risk_level")
      and has("support_tier")
      and has("promotion_status")
      and has("repository_path")
      and has("icon_url")
      and has("image_urls")
      and has("source")
      and has("install")
      and has("search")
      and has("dependencies")
      and has("updated_at")
      and (.channel as $channel | ($channel_defs | has($channel)))
    )
' "$catalog_file" >/dev/null

jq -e '
  [.apps_by_channel[] | .[]]
  | all(.[];
      (.install.files | type == "array" and length > 0)
      and (.image_urls | type == "array")
      and (.dependencies | type == "array")
    )
' "$catalog_file" >/dev/null

jq -e --arg apps_root "$apps_root_rel/" '
  [.apps_by_channel[] | .[]]
  | all(.[]; (.repository_path | startswith($apps_root)))
' "$catalog_file" >/dev/null

jq -e '
  [.apps_by_channel[] | .[]]
  | all(.[];
      . as $app
      | if $app.channel == "incubator" then
          ($app.repository_path | startswith("apps/incubator/" + $app.source.id + "/"))
      else
          ($app.repository_path | startswith("apps/" + $app.channel + "/"))
        end
    )
' "$catalog_file" >/dev/null

non_incubator_count="$(jq '[.apps_by_channel | to_entries[] | select(.key != "incubator") | .value[] | (.channel + ":" + .id)] | length' "$catalog_file")"
non_incubator_unique_count="$(jq '[.apps_by_channel | to_entries[] | select(.key != "incubator") | .value[] | (.channel + ":" + .id)] | unique | length' "$catalog_file")"
if [[ "$non_incubator_count" != "$non_incubator_unique_count" ]]; then
  echo "Duplicate app IDs detected within stable/beta/edge channels" >&2
  exit 1
fi

incubator_count="$(jq '[.apps_by_channel.incubator[]? | (.source.id + ":" + .id)] | length' "$catalog_file")"
incubator_unique_count="$(jq '[.apps_by_channel.incubator[]? | (.source.id + ":" + .id)] | unique | length' "$catalog_file")"
if [[ "$incubator_count" != "$incubator_unique_count" ]]; then
  echo "Duplicate app IDs detected for the same incubator source" >&2
  exit 1
fi

while IFS= read -r app_path; do
  if [[ ! -d "$ROOT_DIR/$app_path" ]]; then
    echo "Missing app directory: $app_path" >&2
    exit 1
  fi
done < <(jq -r '[.apps_by_channel[] | .[] | .repository_path] | .[]' "$catalog_file")

while IFS= read -r icon_path; do
  [[ "$icon_path" == "null" ]] && continue
  if [[ ! -f "$ROOT_DIR/$icon_path" ]]; then
    echo "Missing icon file: $icon_path" >&2
    exit 1
  fi
done < <(jq -r '[.apps_by_channel[] | .[] | .icon_url] | .[]' "$catalog_file")

while IFS= read -r image_path; do
  if [[ ! -f "$ROOT_DIR/$image_path" ]]; then
    echo "Missing image file: $image_path" >&2
    exit 1
  fi
done < <(jq -r '[.apps_by_channel[] | .[] | .image_urls[]] | .[]' "$catalog_file")
