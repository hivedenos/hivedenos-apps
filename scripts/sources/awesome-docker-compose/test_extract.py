#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("extract.py")
SPEC = importlib.util.spec_from_file_location("awesome_docker_compose_extract", MODULE_PATH)
extract = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(extract)


SITEMAP_INDEX_XML = """<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <sitemap><loc>https://awesome-docker-compose.com/sitemap/pages.xml</loc></sitemap>
  <sitemap><loc>https://awesome-docker-compose.com/sitemap/tools.xml</loc></sitemap>
</sitemapindex>
"""


TOOLS_SITEMAP_XML = """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://awesome-docker-compose.com/homepage</loc></url>
  <url><loc>https://awesome-docker-compose.com/uptime-kuma</loc></url>
  <url><loc>https://example.com/ignore-me</loc></url>
</urlset>
"""


DETAIL_HTML = """<!DOCTYPE html>
<html>
  <head>
    <title>Homepage: Create a personal dashboard. - Awesome Docker Compose</title>
    <meta name="description" content="Build a modern dashboard." />
  </head>
  <body>
    <h1>Homepage</h1>
    <h2>Build a modern dashboard.</h2>
    <div>
      <a href="https://gethomepage.dev"><span>Visit Homepage</span></a>
      <a href="https://gethomepage.dev/installation/docker/"><span>Configuration</span></a>
      <a href="https://github.com/gethomepage/homepage"><span>View Repository</span></a>
      <a href="https://github.com/gethomepage/homepage/pkgs/container/homepage"><span>View on GitHub Container Registry</span></a>
    </div>
    <div>
      <a href="/categories/personal-dashboard">Personal Dashboard</a>
    </div>
    <h3>docker-compose.yml</h3>
    <div>
      <pre><code><span>services:</span>
  <span>homepage:</span>
    <span>image:</span> ghcr.io/gethomepage/homepage:latest
    <span>restart:</span> unless-stopped</code></pre>
    </div>
  </body>
</html>
"""


class DiscoverRoutesFromSitemapTests(unittest.TestCase):
    def test_discovers_tool_routes_from_tools_sitemap(self) -> None:
        original_fetch_text = extract.fetch_text

        def fake_fetch_text(url: str, timeout: int = 60) -> str:
            if url.endswith("/sitemap.xml"):
                return SITEMAP_INDEX_XML
            if url.endswith("/sitemap/tools.xml"):
                return TOOLS_SITEMAP_XML
            raise AssertionError(f"unexpected URL: {url}")

        extract.fetch_text = fake_fetch_text
        try:
            routes, source_revision = extract.discover_routes_from_sitemap(
                "https://awesome-docker-compose.com"
            )
        finally:
            extract.fetch_text = original_fetch_text

        self.assertEqual(routes, ["/homepage", "/uptime-kuma"])
        self.assertTrue(source_revision.startswith("html-"))


class ExtractAppFromHtmlTests(unittest.TestCase):
    def test_extracts_metadata_and_compose_from_detail_page(self) -> None:
        app = extract.extract_app_from_html(
            "https://awesome-docker-compose.com",
            "/homepage",
            DETAIL_HTML,
        )

        self.assertEqual(app["title"], "Homepage")
        self.assertEqual(app["description"], "Build a modern dashboard.")
        self.assertEqual(app["category_slug"], "personal-dashboard")
        self.assertEqual(app["website"], "https://gethomepage.dev")
        self.assertEqual(
            app["repo"], "https://github.com/gethomepage/homepage"
        )
        self.assertEqual(
            app["support"], "https://gethomepage.dev/installation/docker/"
        )
        self.assertEqual(
            app["docker_hub"],
            "https://github.com/gethomepage/homepage/pkgs/container/homepage",
        )
        self.assertIn("ghcr.io/gethomepage/homepage:latest", app["compose"])
        self.assertEqual(app["compose_status"], "as-is")
        self.assertEqual(app["version"], "latest")
        self.assertEqual(app["developer"], "gethomepage")


if __name__ == "__main__":
    unittest.main()
