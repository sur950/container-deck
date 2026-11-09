#!/usr/bin/env python3
"""Write website/badges/downloads.json, a shields.io endpoint badge for the README.

shields.io's own GitHub downloads badge counts every release file, checksums and signatures
included. The app's About page and the website count only the installers (.dmg and .pkg),
so the README uses this file to show the same number. Built by .github/workflows/pages.yml.

    GH_TOKEN=... python3 scripts/badge_stats.py
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import urllib.request

REPO = "sur950/container-deck"
OUT = pathlib.Path(__file__).resolve().parent.parent / "website" / "badges" / "downloads.json"
INSTALLER = re.compile(r"\.(pkg|dmg)$", re.IGNORECASE)


def get(url: str):
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "container-deck-pages"})
    token = os.environ.get("GH_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def installer_downloads() -> int:
    total, page = 0, 1
    while True:
        releases = get(f"https://api.github.com/repos/{REPO}/releases?per_page=100&page={page}")
        for release in releases:
            for asset in release.get("assets", []):
                if INSTALLER.search(asset.get("name", "")):
                    total += asset.get("download_count", 0)
        if len(releases) < 100:
            return total
        page += 1


def compact(value: int) -> str:
    """Same rules as CountFormat.compact in the app: 999, 1.2K, 15K, 1M, 2.5M."""
    if value < 1000:
        return str(value)
    units = ((1_000, "K"), (1_000_000, "M"), (1_000_000_000, "B"), (1_000_000_000_000, "T"))
    for index, (base, suffix) in enumerate(units):
        tenth = base // 10
        tenths = value // tenth + (1 if value % tenth >= tenth // 2 else 0)
        if tenths < 100:
            return f"{tenths // 10}{suffix}" if tenths % 10 == 0 else f"{tenths // 10}.{tenths % 10}{suffix}"
        whole = value // base + (1 if value % base >= base // 2 else 0)
        if whole < 1000 or index == len(units) - 1:
            return f"{whole}{suffix}"
    return str(value)


def main() -> None:
    badge = {"schemaVersion": 1, "label": "downloads", "message": compact(installer_downloads()), "color": "B3122E", "cacheSeconds": 3600}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(badge) + "\n")
    print(f"{OUT.relative_to(OUT.parent.parent.parent)}: {badge['message']}")


if __name__ == "__main__":
    main()
