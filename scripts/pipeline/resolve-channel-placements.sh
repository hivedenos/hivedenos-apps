#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$1"
IN_JSON="$2"
OUT_JSON="$3"

pipeline_file="$ROOT_DIR/config/pipeline.json"
apps_root_rel="$(jq -r '.output.apps_root // "apps"' "$pipeline_file")"

channel_order_json="$(jq -c '.channels.order // ["stable", "beta", "edge", "incubator"]' "$pipeline_file")"
channel_defs_json="$(jq -c '.channels.definitions // {}' "$pipeline_file")"
mapfile -t channel_order < <(jq -r '.channels.order // ["stable", "beta", "edge", "incubator"] | .[]' "$pipeline_file")

if [[ ! -f "$IN_JSON" ]]; then
  echo "Missing merged input: $IN_JSON" >&2
  exit 1
fi

tmp_ndjson="$(mktemp)"
trap 'rm -f "$tmp_ndjson"' EXIT

while IFS= read -r app_json; do
  [[ -z "$app_json" ]] && continue

  app_id="$(jq -r '.id // empty' <<<"$app_json")"
  [[ -z "$app_id" ]] && continue

  source_id="$(jq -r '.source.id // empty' <<<"$app_json")"
  origin_channel="$(jq -r '.origin_channel // .channel // "stable"' <<<"$app_json")"
  base_promotion="$(jq -r '.promotion_status // "none"' <<<"$app_json")"
  if [[ -z "$base_promotion" || "$base_promotion" == "null" ]]; then
    base_promotion="none"
  fi

  placements_found=0
  for channel in "${channel_order[@]}"; do
    if [[ "$channel" == "incubator" ]]; then
      [[ -z "$source_id" ]] && continue
      repository_path="$apps_root_rel/incubator/$source_id/$app_id"
    else
      repository_path="$apps_root_rel/$channel/$app_id"
    fi

    if [[ -d "$ROOT_DIR/$repository_path" ]]; then
      asset_subdir=""
      if [[ -d "$ROOT_DIR/$repository_path/img" ]]; then
        asset_subdir="img"
      elif [[ -d "$ROOT_DIR/$repository_path/imgs" ]]; then
        asset_subdir="imgs"
      fi

      jq -cn \
        --argjson app "$app_json" \
        --arg channel "$channel" \
        --arg repository_path "$repository_path" \
        --arg asset_subdir "$asset_subdir" \
        --arg origin_channel "$origin_channel" \
        --arg base_promotion "$base_promotion" \
        --argjson channel_defs "$channel_defs_json" \
        '
        def brandify($value):
          if ($value | type) != "string" then
            $value
          else
            $value
            | gsub("umbrelOS"; "hivedenOS")
            | gsub("UmbrelOS"; "HivedenOS")
            | gsub("Umbrel App Store"; "Hiveden App Store")
            | gsub("umbrel app store"; "hiveden app store")
            | gsub("umbrel\\.local"; "hiveden.local")
            | gsub("Umbrel"; "Hiveden")
            | gsub("umbrel"; "hiveden")
          end;

        def maybe_brandify($value):
          if $channel == "incubator" then
            $value
          else
            brandify($value)
          end;

        def remap_icon_url($url):
          if $url == null then
            null
          elif ($asset_subdir | length) == 0 then
            $url
          else
            $repository_path + "/" + $asset_subdir + "/" + ($url | split("/") | last)
          end;

        def remap_image_urls($urls):
          if ($urls | type) != "array" then
            []
          elif ($asset_subdir | length) == 0 then
            $urls
          else
            ($urls | map($repository_path + "/" + $asset_subdir + "/" + (split("/") | last)))
          end;

        ($channel_defs[$channel] // {}) as $meta
        | $app + {
            name: maybe_brandify($app.name),
            tagline: maybe_brandify($app.tagline),
            description: maybe_brandify($app.description),
            developer: maybe_brandify($app.developer),
            channel: $channel,
            channel_label: ($meta.label // $channel),
            risk_level: ($meta.risk_level // "unknown"),
            support_tier: ($meta.support_tier // "community"),
            repository_path: $repository_path,
            icon_url: remap_icon_url($app.icon_url),
            image_urls: remap_image_urls(($app.image_urls // [])),
            search: (
              ($app.search // {})
              + {
                  keywords: (
                    (($app.search.keywords // []) | map(maybe_brandify(.)))
                    + (if $channel == "incubator" then [] else ["hiveden"] end)
                    | map(select((. | type) == "string" and (length > 0)))
                    | unique
                  ),
                  categories: (($app.search.categories // []) | map(select((. | type) == "string" and (length > 0))))
                }
            ),
            promotion_status: (if $channel == $origin_channel then $base_promotion else "promoted" end)
          }
        ' >>"$tmp_ndjson"
      placements_found=1
    fi
  done

  if [[ "$placements_found" -eq 0 ]]; then
    fallback_repository_path="$(jq -r '.repository_path // empty' <<<"$app_json")"
    if [[ -n "$fallback_repository_path" && -d "$ROOT_DIR/$fallback_repository_path" ]]; then
      printf '%s\n' "$app_json" >>"$tmp_ndjson"
    fi
  fi
done < <(jq -c '.[]' "$IN_JSON")

if [[ ! -s "$tmp_ndjson" ]]; then
  echo '[]' >"$OUT_JSON"
  exit 0
fi

jq -s \
  --argjson channel_order "$channel_order_json" \
  '
  def channel_rank($channel): ($channel_order | index($channel)) // 999999;

  sort_by(channel_rank(.channel // "stable"), (.source.priority // 999999), .id, (.source.id // ""))
  | reduce .[] as $app (
      [];
      if ($app.channel // "stable") == "incubator" then
        if any(.[]; (.channel // "stable") == "incubator" and .id == $app.id and ((.source.id // "") == ($app.source.id // ""))) then
          .
        else
          . + [$app]
        end
      elif any(.[]; (.channel // "stable") == ($app.channel // "stable") and .id == $app.id) then
        .
      else
        . + [$app]
      end
    )
  | sort_by(channel_rank(.channel // "stable"), .id, (.source.id // ""))
  ' "$tmp_ndjson" >"$OUT_JSON"
