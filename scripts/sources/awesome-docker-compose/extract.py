#!/usr/bin/env python3
import argparse
import json
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import quote, unquote, urljoin, urlparse
from urllib.request import Request, urlopen

import yaml


USER_AGENT = "hivedenos-apps-sync/1.0"


def fetch_text(url: str, timeout: int = 60) -> str:
    req = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(req, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def decode_js_string(value: str) -> str:
    return bytes(value, "utf-8").decode("unicode_escape")


def slugify(value: str) -> str:
    value = value.lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = re.sub(r"-+", "-", value).strip("-")
    return value


def normalize_channel(channel: str) -> str:
    allowed = {"stable", "beta", "edge", "incubator"}
    if channel in allowed:
        return channel
    return "incubator"


def extract_build_id(home_html: str) -> Optional[str]:
    match = re.search(r'"buildId":"([^"]+)"', home_html)
    if not match:
        return None
    return match.group(1)


def parse_route_chunks(manifest_js: str) -> Dict[str, str]:
    route_to_chunk: Dict[str, str] = {}
    for route, array_text in re.findall(r'"(/apps/[^"]+)":\[(.*?)\]', manifest_js):
        chunk_match = re.search(r'"(static/chunks/pages/apps/[^"]+\.js)"', array_text)
        if chunk_match:
            route_to_chunk[route] = chunk_match.group(1)

    leaf_routes: Dict[str, str] = {}
    all_routes = set(route_to_chunk.keys())
    for route, chunk in route_to_chunk.items():
        if route in {"/apps", "/apps/"}:
            continue
        if "/_meta" in route:
            continue
        if route == "/apps/A-Template":
            continue
        prefix = route + "/"
        if any(other.startswith(prefix) for other in all_routes if other != route):
            continue
        leaf_routes[route] = chunk

    return leaf_routes


def find_first(matchers: List[re.Pattern[str]], text: str) -> Optional[str]:
    for matcher in matchers:
        match = matcher.search(text)
        if match:
            return decode_js_string(match.group(1)).strip()
    return None


def extract_title(chunk_js: str) -> str:
    title = find_first(
        [
            re.compile(r'\.h1,\{children:"((?:\\.|[^"\\])*)"\}'),
            re.compile(r'title:"((?:\\.|[^"\\])*)"\}'),
        ],
        chunk_js,
    )
    return title or "Untitled App"


def extract_description(chunk_js: str) -> str:
    description = find_first(
        [
            re.compile(r'\.p,\{children:"((?:\\.|[^"\\])*)"\}'),
        ],
        chunk_js,
    )
    return description or ""


def extract_children_array(chunk_js: str, marker: str) -> Optional[str]:
    marker_index = chunk_js.find(marker)
    if marker_index < 0:
        return None

    children_index = chunk_js.find("children:[", marker_index)
    if children_index < 0:
        return None

    cursor = children_index + len("children:[")
    depth = 1
    in_string = False
    escape = False
    quote = ""
    out: List[str] = []

    while cursor < len(chunk_js):
        ch = chunk_js[cursor]
        out.append(ch)
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                in_string = False
        else:
            if ch in ('"', "'"):
                in_string = True
                quote = ch
            elif ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
                if depth == 0:
                    out.pop()
                    return "".join(out)
        cursor += 1

    return None


def extract_compose(chunk_js: str) -> Optional[str]:
    array_text = extract_children_array(chunk_js, 'data-language":"yaml"')
    if not array_text:
        return None

    lines: List[str] = []
    for segment in array_text.split(',"\\n",'):
        pieces = re.findall(r'children:"((?:\\.|[^"\\])*)"', segment)
        if not pieces:
            lines.append("")
            continue
        line = "".join(decode_js_string(piece) for piece in pieces)
        lines.append(line)

    while lines and lines[-1] == "":
        lines.pop()

    if not lines:
        return None

    compose_text = "\n".join(lines) + "\n"
    compose_text = compose_text.replace("\r\n", "\n").replace("\r", "\n")
    compose_text = compose_text.replace("\t", "  ")
    return compose_text


def extract_resources(chunk_js: str) -> Dict[str, str]:
    resources: Dict[str, str] = {}
    pattern = re.compile(
        r'children:\["(Website|GitHub|Docker Hub|Configuration): ",'
        r'\([^)]*\)\([^,]+,\{href:"([^"]+)"'
    )
    for key, value in pattern.findall(chunk_js):
        resources[key] = decode_js_string(value)
    return resources


def normalize_url(url_value: Optional[str], base_url: str) -> Optional[str]:
    if not url_value:
        return None

    value = url_value.strip()
    if not value:
        return None

    if value.startswith("//"):
        return "https:" + value

    parsed = urlparse(value)
    if parsed.scheme:
        return value

    return urljoin(base_url.rstrip("/") + "/", value.lstrip("/"))


def compose_is_valid(compose_text: str) -> bool:
    try:
        parsed = yaml.safe_load(compose_text)
    except Exception:
        return False

    if not isinstance(parsed, dict):
        return False

    services = parsed.get("services")
    if not isinstance(services, dict) or not services:
        return False

    return True


def repair_compose_text(compose_text: str) -> str:
    lines: List[str] = []
    normalized = (
        compose_text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "  ")
    )

    for line in normalized.split("\n"):
        current = line.rstrip()
        stripped = current.strip()

        if stripped == ",":
            continue

        if re.match(r"^\s*version\s*:\s*$", current):
            current = 'version: "3.8"'

        current = re.sub(r",(\s*(#.*)?)$", r"\1", current)
        lines.append(current)

    repaired = "\n".join(lines).strip() + "\n"
    return repaired


def image_from_docker_hub(docker_hub_url: Optional[str]) -> Optional[str]:
    if not docker_hub_url:
        return None

    parsed = urlparse(docker_hub_url)
    if "docker.com" not in parsed.netloc.lower():
        return None

    parts = [segment for segment in parsed.path.split("/") if segment]
    if not parts:
        return None

    repo: Optional[str] = None
    if parts[0] == "r" and len(parts) >= 2:
        if len(parts) >= 3:
            repo = f"{parts[1]}/{parts[2]}"
        else:
            repo = parts[1]
    elif parts[0] == "_" and len(parts) >= 2:
        repo = parts[1]

    if not repo:
        return None

    return f"docker.io/{repo}:latest"


def first_image_reference(compose_text: str) -> Optional[str]:
    for line in compose_text.splitlines():
        match = re.match(r"\s*image\s*[:=]\s*([^\n#]+)", line)
        if not match:
            continue

        image = match.group(1).strip().strip("\"'")
        image = re.sub(r"\s+$", "", image)
        image = re.sub(r",$", "", image)
        if image:
            return image

    return None


def build_fallback_compose(
    base_id: str, raw_compose: str, docker_hub_url: Optional[str]
) -> str:
    image = first_image_reference(raw_compose)
    if not image:
        image = image_from_docker_hub(docker_hub_url)
    if not image:
        image = "ghcr.io/example/app:latest"

    service_name = base_id or "app"
    return (
        'version: "3.8"\n\n'
        "services:\n"
        f"  {service_name}:\n"
        f"    image: {image}\n"
        "    restart: unless-stopped\n"
    )


def sanitize_compose(
    base_id: str, compose_text: str, docker_hub_url: Optional[str]
) -> Tuple[str, str]:
    if compose_is_valid(compose_text):
        return compose_text, "as-is"

    repaired = repair_compose_text(compose_text)
    if compose_is_valid(repaired):
        return repaired, "repaired"

    fallback = build_fallback_compose(base_id, repaired, docker_hub_url)
    return fallback, "fallback"


def extract_image_version(compose_text: str) -> str:
    for line in compose_text.splitlines():
        match = re.match(r"\s*image\s*:\s*([^\s#]+)", line)
        if not match:
            continue
        image = match.group(1).strip().strip("\"'")
        image = image.split("@", 1)[0]
        if ":" in image:
            return image.rsplit(":", 1)[1]
    return "latest"


def first_sentence(text: str, max_len: int = 120) -> str:
    text = text.strip()
    if not text:
        return ""
    sentence_match = re.search(r"(.+?[.!?])(?:\s|$)", text)
    if sentence_match:
        sentence = sentence_match.group(1).strip()
    else:
        sentence = text
    if len(sentence) <= max_len:
        return sentence
    return sentence[: max_len - 1].rstrip() + "..."


def github_owner(github_url: Optional[str]) -> Optional[str]:
    if not github_url:
        return None
    parsed = urlparse(github_url)
    if "github.com" not in parsed.netloc.lower():
        return None
    parts = [p for p in parsed.path.split("/") if p]
    if not parts:
        return None
    return parts[0]


def choose_ids(entries: List[dict]) -> None:
    base_counter = Counter(entry["base_id"] for entry in entries)
    used: set[str] = set()

    for entry in entries:
        base_id = entry["base_id"]
        category_slug = entry["category_slug"]

        if base_counter[base_id] == 1:
            candidate = base_id
        else:
            suffix = category_slug or "app"
            candidate = f"{base_id}-{suffix}"

        original = candidate
        idx = 2
        while candidate in used:
            candidate = f"{original}-{idx}"
            idx += 1

        used.add(candidate)
        entry["id"] = candidate


def write_app(app_dir: Path, app_data: dict) -> None:
    app_dir.mkdir(parents=True, exist_ok=True)

    compose_path = app_dir / "docker-compose.yml"
    compose_path.write_text(app_data["compose"], encoding="utf-8")

    manifest = {
        "manifestVersion": 1.1,
        "id": app_data["id"],
        "category": app_data["category_slug"] or "utilities",
        "name": app_data["title"],
        "version": app_data["version"],
        "tagline": app_data["tagline"],
        "description": app_data["description"],
        "developer": app_data["developer"],
        "dependencies": [],
        "gallery": [],
        "path": "/",
        "defaultUsername": "",
        "deterministicPassword": False,
        "torOnly": False,
        "submitter": "Hiveden",
    }

    if app_data["website"]:
        manifest["website"] = app_data["website"]
    if app_data["repo"]:
        manifest["repo"] = app_data["repo"]
    if app_data["support"]:
        manifest["support"] = app_data["support"]

    manifest_path = app_dir / "hiveden-app.yml"
    manifest_path.write_text(
        yaml.safe_dump(manifest, sort_keys=False, allow_unicode=False),
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract Awesome Docker Compose apps")
    parser.add_argument("--source-config-json", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--commit-file", required=True)
    args = parser.parse_args()

    source_cfg = json.loads(args.source_config_json)
    base_url = source_cfg.get("repo_url", "https://awesome-docker-compose.com").rstrip(
        "/"
    )
    channel = normalize_channel(source_cfg.get("channel") or "beta")
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    home_html = fetch_text(base_url + "/")
    build_id = extract_build_id(home_html)
    if not build_id:
        raise RuntimeError("Could not determine Next.js build id")

    manifest_url = f"{base_url}/_next/static/{build_id}/_buildManifest.js"
    manifest_js = fetch_text(manifest_url)

    route_to_chunk = parse_route_chunks(manifest_js)
    if not route_to_chunk:
        raise RuntimeError("No app routes found in build manifest")

    extracted: List[dict] = []
    compose_status_counts: Counter[str] = Counter()
    for route, chunk_path in sorted(route_to_chunk.items()):
        route_segments = [unquote(seg) for seg in route.strip("/").split("/")]
        if len(route_segments) < 3:
            continue

        category_parts = route_segments[1:-1]
        app_slug = route_segments[-1]
        category_slug = slugify("-".join(category_parts))
        base_id = slugify(app_slug)
        if not base_id:
            continue

        normalized_chunk_path = quote(chunk_path.strip(), safe="/")
        chunk_url = urljoin(base_url + "/", "_next/" + normalized_chunk_path)
        chunk_js = fetch_text(chunk_url)

        resources = extract_resources(chunk_js)
        website = normalize_url(resources.get("Website"), base_url)
        github = normalize_url(resources.get("GitHub"), base_url)
        config = normalize_url(resources.get("Configuration"), base_url)
        docker_hub = normalize_url(resources.get("Docker Hub"), base_url)

        title = extract_title(chunk_js)
        description = extract_description(chunk_js)
        compose = extract_compose(chunk_js)
        if not compose:
            compose = build_fallback_compose(base_id, "", docker_hub)
            compose_status = "fallback"
        else:
            compose, compose_status = sanitize_compose(base_id, compose, docker_hub)
        compose_status_counts[compose_status] += 1

        route_url = urljoin(base_url + "/", route.lstrip("/"))
        if not website:
            website = route_url
        repo = github or config or route_url
        support = config or github or route_url
        developer = github_owner(github) or "Awesome Docker Compose"
        version = extract_image_version(compose)

        if not description:
            description = title
        tagline = first_sentence(description) or title

        extracted.append(
            {
                "route": route,
                "route_url": route_url,
                "base_id": base_id,
                "category_slug": category_slug,
                "title": title,
                "description": description,
                "tagline": tagline,
                "compose": compose,
                "version": version,
                "developer": developer,
                "website": website,
                "repo": repo,
                "support": support,
                "docker_hub": docker_hub,
                "channel": channel,
                "compose_status": compose_status,
            }
        )

    choose_ids(extracted)

    for app_data in extracted:
        write_app(out_dir / app_data["id"], app_data)

    commit_path = Path(args.commit_file)
    commit_path.write_text(build_id + "\n", encoding="utf-8")

    stats = {
        "generated_at": datetime.now(tz=timezone.utc).isoformat(),
        "base_url": base_url,
        "build_id": build_id,
        "total_apps": len(extracted),
        "compose_status_counts": dict(compose_status_counts),
    }
    (out_dir / ".source-stats.json").write_text(
        json.dumps(stats, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        raise
