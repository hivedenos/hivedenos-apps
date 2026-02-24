#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$1"
SOURCE_CONFIG_JSON="$2"
APPS_LIST_FILE="$3"
COMMIT_SHA="$4"
OUT_JSON="$5"

python3 - "$REPO_DIR" "$SOURCE_CONFIG_JSON" "$APPS_LIST_FILE" "$COMMIT_SHA" "$OUT_JSON" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml


repo_dir = Path(sys.argv[1])
source_cfg = json.loads(sys.argv[2])
apps_list_file = Path(sys.argv[3])
commit_sha = sys.argv[4]
out_json = Path(sys.argv[5])

source_id = source_cfg.get("id", "awesome-docker-compose")
repo_url = source_cfg.get("repo_url", "https://awesome-docker-compose.com")
priority = source_cfg.get("priority", 999999)

channel = source_cfg.get("channel", "incubator")
if channel not in {"stable", "beta", "edge", "incubator"}:
    channel = "incubator"

channel_meta = {
    "stable": {"label": "Official", "risk": "low", "support": "official"},
    "beta": {"label": "Beta", "risk": "medium", "support": "official"},
    "edge": {"label": "Edge", "risk": "high", "support": "experimental"},
    "incubator": {"label": "Incubator", "risk": "high", "support": "candidate"},
}


def normalize_image_name(image_ref):
    image = str(image_ref).strip().strip('"').strip("'")
    image = image.split("@", 1)[0]
    image = image.rsplit("/", 1)[-1]
    if ":" in image:
        image = image.split(":", 1)[0]
    return image


def parse_dependencies(compose_path: Path):
    try:
        compose = yaml.safe_load(compose_path.read_text(encoding="utf-8")) or {}
    except Exception:
        return []

    services = compose.get("services")
    if not isinstance(services, dict):
        return []

    service_images = {}
    for service_name, service_cfg in services.items():
        if not isinstance(service_cfg, dict):
            continue
        image = service_cfg.get("image")
        if image:
            service_images[str(service_name)] = normalize_image_name(image)

    dependencies = set()
    for service_cfg in services.values():
        if not isinstance(service_cfg, dict):
            continue
        depends_on = service_cfg.get("depends_on")
        if isinstance(depends_on, list):
            for dep in depends_on:
                dep_name = str(dep)
                dependencies.add(service_images.get(dep_name, dep_name))
        elif isinstance(depends_on, dict):
            for dep_name in depends_on.keys():
                dep_str = str(dep_name)
                dependencies.add(service_images.get(dep_str, dep_str))

    return sorted(dep for dep in dependencies if dep)


def manifest_value(manifest, key, default=""):
    value = manifest.get(key, default)
    if value is None:
        return default
    return str(value)


records = []
updated_at = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

for line in apps_list_file.read_text(encoding="utf-8").splitlines():
    app_dir = Path(line.strip())
    if not line.strip():
        continue

    compose_path = app_dir / "docker-compose.yml"
    manifest_path = app_dir / "hiveden-app.yml"
    if not manifest_path.exists():
        manifest_path = app_dir / "hiveden-app.yaml"

    if not compose_path.exists() or not manifest_path.exists():
        continue

    try:
        manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
    except Exception:
        manifest = {}

    app_id = manifest_value(manifest, "id", app_dir.name)
    name = manifest_value(manifest, "name", app_id)
    version = manifest_value(manifest, "version", "unknown")
    tagline = manifest_value(manifest, "tagline", name)
    description = manifest_value(manifest, "description", tagline)
    developer = manifest_value(manifest, "developer", "Awesome Docker Compose")
    category = manifest_value(manifest, "category", "utilities")

    dependencies = parse_dependencies(compose_path)
    rel_path = str(app_dir.relative_to(repo_dir))
    compose_rel = str(compose_path.relative_to(repo_dir))
    manifest_rel = str(manifest_path.relative_to(repo_dir))

    meta = channel_meta[channel]
    if channel == "incubator":
        repository_path = f"apps/incubator/{source_id}/{app_id}"
    else:
        repository_path = f"apps/{channel}/{app_id}"

    records.append(
        {
            "id": app_id,
            "name": name,
            "version": version,
            "tagline": tagline,
            "description": description,
            "developer": developer,
            "channel": channel,
            "channel_label": meta["label"],
            "risk_level": meta["risk"],
            "support_tier": meta["support"],
            "origin_channel": channel,
            "promotion_status": "none",
            "repository_path": repository_path,
            "source": {
                "id": source_id,
                "repo": repo_url,
                "commit": commit_sha,
                "path": rel_path,
                "priority": priority,
            },
            "install": {
                "method": "docker-compose",
                "files": [compose_rel, manifest_rel],
            },
            "search": {
                "keywords": [item for item in [app_id, name, developer, category] if item],
                "categories": [category] if category else [],
            },
            "dependencies": dependencies,
            "updated_at": updated_at,
        }
    )

records.sort(key=lambda item: item.get("id", ""))
out_json.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
PY
