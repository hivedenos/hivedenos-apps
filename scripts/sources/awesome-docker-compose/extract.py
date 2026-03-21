#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from html import unescape
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple
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
    for pattern in (
        r'"buildId":"([^"]+)"',
        r'"buildId"\s*:\s*"([^"]+)"',
        r'/_next/static/([^"/]+)/_buildManifest\.js',
    ):
        match = re.search(pattern, home_html)
        if match:
            return match.group(1)
    return None


def extract_source_revision(home_html: str) -> str:
    build_id = extract_build_id(home_html)
    if build_id:
        return build_id

    digest = hashlib.sha256(home_html.encode("utf-8")).hexdigest()
    return f"html-{digest[:16]}"


def strip_tags(fragment: str) -> str:
    return re.sub(r"<[^>]+>", "", fragment)


def normalize_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", unescape(text)).strip()


def extract_anchor_links(page_html: str) -> List[Tuple[str, str]]:
    links: List[Tuple[str, str]] = []
    for href, inner_html in re.findall(
        r'<a\b[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
        page_html,
        re.S,
    ):
        label = normalize_whitespace(strip_tags(inner_html))
        links.append((unescape(href), label))
    return links


def find_link_by_label(links: Iterable[Tuple[str, str]], pattern: str) -> Optional[str]:
    matcher = re.compile(pattern)
    for href, label in links:
        if matcher.fullmatch(label):
            return href
    return None


def extract_list_page_count(home_html: str) -> int:
    pages = [int(page) for page in re.findall(r'href="/\?page=(\d+)"', home_html)]
    if not pages:
        return 1
    return max(pages)


def extract_routes_from_list_page(list_html: str) -> List[str]:
    routes: List[str] = []
    seen: set[str] = set()
    for route in re.findall(r'<h3[^>]*>\s*<a href="(/[^"?#]+)"', list_html):
        if route in seen:
            continue
        if route in {"/", "/about", "/blog", "/categories", "/submit", "/tags"}:
            continue
        seen.add(route)
        routes.append(route)
    return routes


def extract_title_from_html(page_html: str) -> str:
    match = re.search(r"<h1[^>]*>(.*?)</h1>", page_html, re.S)
    if match:
        title = normalize_whitespace(strip_tags(match.group(1)))
        if title:
            return title

    match = re.search(r"<title>(.*?)</title>", page_html, re.S)
    if not match:
        return "Untitled App"

    title = normalize_whitespace(strip_tags(match.group(1)))
    title = re.sub(r"\s+[–-]\s+Awesome Docker Compose$", "", title)
    title = title.split(":", 1)[0].strip()
    return title or "Untitled App"


def extract_description_from_html(page_html: str) -> str:
    match = re.search(r'<meta name="description" content="([^"]*)"', page_html)
    if match:
        return normalize_whitespace(match.group(1))

    match = re.search(r"<h2[^>]*>(.*?)</h2>", page_html, re.S)
    if not match:
        return ""
    return normalize_whitespace(strip_tags(match.group(1)))


def extract_category_slug_from_html(page_html: str) -> str:
    match = re.search(r'href="/categories/([^"]+)"', page_html)
    if not match:
        return ""
    return slugify(unescape(match.group(1)))


def extract_compose_from_html(page_html: str) -> Optional[str]:
    match = re.search(
        r"<h3[^>]*>\s*docker-compose\.yml\s*</h3>.*?<pre[^>]*><code>(.*?)</code></pre>",
        page_html,
        re.S | re.I,
    )
    if not match:
        return None

    code_html = match.group(1)
    compose = unescape(strip_tags(code_html))
    compose = compose.replace("\r\n", "\n").replace("\r", "\n")
    compose = compose.strip("\n")
    if not compose:
        return None
    return compose + "\n"


def extract_sitemap_locs(sitemap_xml: str) -> List[str]:
    return [
        unescape(loc).strip() for loc in re.findall(r"<loc>(.*?)</loc>", sitemap_xml)
    ]


def discover_routes_from_sitemap(base_url: str) -> Tuple[List[str], str]:
    sitemap_url = urljoin(base_url + "/", "sitemap.xml")
    sitemap_xml = fetch_text(sitemap_url)
    locs = extract_sitemap_locs(sitemap_xml)

    tools_sitemap_url = next(
        (loc for loc in locs if loc.rstrip("/").endswith("/sitemap/tools.xml")),
        None,
    )
    tools_sitemap_xml = (
        fetch_text(tools_sitemap_url) if tools_sitemap_url else sitemap_xml
    )

    base_netloc = urlparse(base_url).netloc.lower()
    routes: List[str] = []
    seen: set[str] = set()
    for loc in extract_sitemap_locs(tools_sitemap_xml):
        parsed = urlparse(loc)
        if parsed.netloc and parsed.netloc.lower() != base_netloc:
            continue

        route = parsed.path or "/"
        if route == "/" or route.startswith("/sitemap/"):
            continue

        if route in seen:
            continue
        seen.add(route)
        routes.append(route)

    return routes, extract_source_revision(tools_sitemap_xml)


def discover_routes_from_listing_pages(base_url: str, home_html: str) -> List[str]:
    routes: List[str] = []
    seen: set[str] = set()

    def add_routes(list_html: str) -> None:
        for route in extract_routes_from_list_page(list_html):
            if route in seen:
                continue
            seen.add(route)
            routes.append(route)

    add_routes(home_html)
    page_count = extract_list_page_count(home_html)
    for page in range(2, page_count + 1):
        list_html = fetch_text(f"{base_url}/?page={page}")
        add_routes(list_html)

    return routes


def extract_app_from_html(base_url: str, route: str, page_html: str) -> dict:
    links = extract_anchor_links(page_html)

    website = normalize_url(find_link_by_label(links, r"Visit .+"), base_url)
    github = normalize_url(find_link_by_label(links, r"View Repository"), base_url)
    config = normalize_url(find_link_by_label(links, r"Configuration"), base_url)
    docker_hub = normalize_url(find_link_by_label(links, r"View on .+"), base_url)

    title = extract_title_from_html(page_html)
    description = extract_description_from_html(page_html)
    category_slug = extract_category_slug_from_html(page_html)

    base_id = slugify(route.strip("/"))
    compose = extract_compose_from_html(page_html)
    if not compose:
        compose = build_fallback_compose(base_id, "", docker_hub)
        compose_status = "fallback"
    else:
        compose, compose_status = sanitize_compose(base_id, compose, docker_hub)

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

    return {
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
        "compose_status": compose_status,
    }


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
    source_revision = extract_source_revision(home_html)
    route_source = "sitemap"
    routes: List[str] = []

    try:
        routes, source_revision = discover_routes_from_sitemap(base_url)
    except Exception:
        routes = []

    if not routes:
        routes = discover_routes_from_listing_pages(base_url, home_html)
        route_source = "listing-pages"

    if not routes:
        build_id = extract_build_id(home_html)
        if build_id:
            manifest_url = f"{base_url}/_next/static/{build_id}/_buildManifest.js"
            manifest_js = fetch_text(manifest_url)
            route_to_chunk = parse_route_chunks(manifest_js)
            routes = sorted(route_to_chunk.keys())
            route_source = "legacy-build-manifest"

    if not routes:
        raise RuntimeError(
            "Could not discover app routes from sitemap or fallback paths"
        )

    extracted: List[dict] = []
    compose_status_counts: Counter[str] = Counter()
    for route in routes:
        page_html = fetch_text(urljoin(base_url + "/", route.lstrip("/")))
        app_data = extract_app_from_html(base_url, route, page_html)
        app_data["channel"] = channel
        extracted.append(app_data)
        compose_status_counts[app_data["compose_status"]] += 1

    choose_ids(extracted)

    for app_data in extracted:
        write_app(out_dir / app_data["id"], app_data)

    commit_path = Path(args.commit_file)
    commit_path.write_text(source_revision + "\n", encoding="utf-8")

    stats = {
        "generated_at": datetime.now(tz=timezone.utc).isoformat(),
        "base_url": base_url,
        "build_id": source_revision,
        "source_revision": source_revision,
        "route_source": route_source,
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
        print(
            f"[ERROR] Awesome Docker Compose extraction failed: {exc}", file=sys.stderr
        )
        raise SystemExit(1)
