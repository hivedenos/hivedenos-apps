# hivedenos-apps

Script-first apps ingestion pipeline for Hiveden OS.

## What it does

- Pulls app repositories from configured sources (`config/sources.json`)
- Normalizes app metadata into a common JSON format
- Creates a repository-level app tree under `apps/<app-id>`
- Builds a single backend-ready catalog at `data/apps.json`
- Produces sync metadata at `data/metadata.json`
- Uses `data/sources/` as transient sync workspace (not committed)

## Current source

- Umbrel apps: `https://github.com/getumbrel/umbrel-apps.git`

## Run locally

```bash
chmod +x scripts/run-sync.sh scripts/lib/*.sh scripts/pipeline/*.sh scripts/sources/umbrel/*.sh
./scripts/run-sync.sh
```

## Nightly sync

- GitHub Actions workflow: `.github/workflows/sync-apps.yml`
- Schedule: `0 2 * * *` (nightly UTC)
- Behavior: commits `data/apps.json`, `data/metadata.json`, and `apps/` changes to `main` if sync output changed

## App directory behavior

- Canonical app files are written to `apps/<app-id>`
- App images are synced from `getumbrel/umbrel-apps-gallery` into `apps/<app-id>/imgs/`
- Screenshot files are normalized to `apps/<app-id>/imgs/1.<ext>`, `2.<ext>`, etc.
- Icons are normalized to `apps/<app-id>/imgs/icon.<ext>`
- If multiple sources provide the same app id, later sources are written to `apps/<app-id>--<source-id>`
- Each catalog item includes `repository_path` to locate the app files in this repo
- Each catalog item also includes `tagline`, `description`, `icon_url`, and `image_urls`

## Extending with new sources

1. Add source config to `config/sources.json`
2. Add source scripts under `scripts/sources/<source-id>/`
3. Add dispatch branch in `scripts/run-sync.sh` for the new source `type`
