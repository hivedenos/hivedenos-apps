# hivedenos-apps

Script-first apps ingestion pipeline for Hiveden OS.

## What it does

- Pulls app repositories from configured sources (`config/sources.json`)
- Normalizes app metadata into a common JSON format
- Creates a channel-aware repository app tree under `apps/` (`apps/<channel>/<app-id>` and `apps/incubator/<source-id>/<app-id>`)
- Builds a single backend-ready catalog at `data/apps.json`
- Produces sync metadata at `data/metadata.json`
- Uses `data/sources/` as transient sync workspace (not committed)
- Records channel promotion audit entries in `config/channel-overrides.json`

## Current source

- Umbrel apps: `https://github.com/getumbrel/umbrel-apps.git`

## Channels

- `stable` (Official): production-ready apps
- `beta`: mostly safe apps with potential small changes
- `edge`: experimental apps where behavior may change frequently
- `incubator`: candidate apps grouped by source before promotion

By default, source ingestion writes apps to `incubator` (`channels.ingest_source_channel` in `config/pipeline.json`).

`data/apps.json` keeps compatibility by exposing:

- `apps`: apps from the default channel (`stable`)
- `apps_by_channel`: all channels
- `channels`: per-channel totals and warnings

## Run locally

```bash
chmod +x scripts/run-sync.sh scripts/lib/*.sh scripts/pipeline/*.sh scripts/sources/umbrel/*.sh scripts/channels/*.sh
./scripts/run-sync.sh
```

## Nightly sync

- GitHub Actions workflow: `.github/workflows/sync-apps.yml`
- Schedule: `0 2 * * *` (nightly UTC)
- Behavior: commits `data/apps.json`, `data/metadata.json`, and `apps/` changes to `main` if sync output changed

## App directory behavior

- Canonical app files are written by channel:
  - `apps/stable/<app-id>`
  - `apps/beta/<app-id>`
  - `apps/edge/<app-id>`
  - `apps/incubator/<source-id>/<app-id>`
- `run-sync.sh` ingests source apps into `apps/incubator/<source-id>/...`
- `run-sync.sh` resolves `data/apps.json` by checking all channel directories under `apps/`
- On each sync, only `apps/incubator/` is fully regenerated; non-incubator channel directories are preserved
- App images are synced from `getumbrel/umbrel-apps-gallery` into each app's `img/` directory
- Screenshot files are normalized to `<repository_path>/img/1.<ext>`, `2.<ext>`, etc.
- Icons are normalized to `<repository_path>/img/icon.<ext>`
- If multiple sources provide the same app id in the same channel, later sources are written with `--<source-id>` suffix
- Each catalog item includes `repository_path` to locate the app files in this repo
- Each catalog item also includes `tagline`, `description`, `icon_url`, and `image_urls`
- Each catalog item includes `dependencies` resolved from `docker-compose.yml` (`depends_on`), mapping generic service names like `db` to their container image names (for example `postgres`, `mariadb`) when available

## Promote apps between channels

Use the promotion helper to place an app directory into another channel:

```bash
./scripts/channels/promote-app.sh <app-id> <from-channel> <to-channel> [source-id]
```

Examples:

```bash
./scripts/channels/promote-app.sh nostr-relay edge beta umbrel
./scripts/channels/promote-app.sh my-app incubator edge custom-source
```

Promotion behavior:

- If `from-channel` is `incubator`, the app directory is copied to the destination channel
- Otherwise, the app directory is moved to the destination channel
- An audit record is written to `config/channel-overrides.json`

Then run `./scripts/run-sync.sh` to regenerate `data/apps.json` and `data/metadata.json`.

## Extending with new sources

1. Add source config to `config/sources.json`
2. Add source scripts under `scripts/sources/<source-id>/`
3. Add dispatch branch in `scripts/run-sync.sh` for the new source `type`
