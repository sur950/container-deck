#!/usr/bin/env python3
"""Render the guides in Markdown into styled pages for the website.

The Markdown files stay the single source. This writes website/docs/<name>.html for each
guide (git-ignored, built by .github/workflows/pages.yml) and website/sitemap.xml.

    pip install markdown pygments
    python3 scripts/build_docs.py

The header, footer, icon sprite and download dialog are copied from website/index.html,
so the guides always match the home page.

Diagrams: a ```mermaid block right after a <!-- diagram: name --> comment is what GitHub
shows. On the site it is replaced by docs/diagrams/<name>.svg, inlined so docs.css can
color it for Light and Dark. An optional <name>-narrow.svg is shown on phones instead.
"""

from __future__ import annotations

import datetime as dt
import html
import os
import posixpath
import re
import subprocess
import sys
from pathlib import Path

try:
    import markdown
    from markdown.extensions.toc import slugify
except ImportError:  # pragma: no cover
    sys.exit("build_docs.py needs the markdown and pygments packages: pip install markdown pygments")

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "website"
OUT = SITE / "docs"
DIAGRAMS = ROOT / "docs" / "diagrams"
REPO = "https://github.com/sur950/container-deck"
SITE_URL = "https://sur950.github.io/container-deck/"

# Source file, page name, short label for the guide list.
GUIDES = [
    ("docs/COMPOSE.md", "compose", "Coming from Docker Compose"),
    ("docs/DOCKER.md", "docker", "Docker commands"),
    ("docs/DOMAINS.md", "domains", "Domains and sharing"),
    ("docs/ARCHITECTURE.md", "architecture", "Architecture"),
    ("docs/DEVELOPMENT.md", "development", "Development"),
    ("CHANGELOG.md", "changelog", "Changelog"),
    ("CONTRIBUTING.md", "contributing", "Contributing"),
    ("SECURITY.md", "security", "Security"),
]
PAGE_FOR_SOURCE = {src: name for src, name, _ in GUIDES}

COPY_BUTTON = (
    '<button type="button" class="copy-btn" data-copy>'
    '<svg class="icon i-copy" aria-hidden="true"><use href="#i-copy"/></svg>'
    '<svg class="icon i-done" aria-hidden="true"><use href="#i-check"/></svg>'
    '<span class="copy-label">Copy</span></button>'
)


def git_date(path: str) -> dt.date | None:
    """Date of the last commit that touched the file, or None outside a git checkout."""
    try:
        out = subprocess.run(
            ["git", "log", "-1", "--format=%cs", "--", path],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout.strip()
        return dt.date.fromisoformat(out) if out else None
    except (OSError, subprocess.CalledProcessError, ValueError):
        return None


def human_date(day: dt.date) -> str:
    return f"{day.day} {day.strftime('%B %Y')}"


def block(source: str, start: str, end: str) -> str:
    """The first chunk of index.html from `start` up to and including `end`."""
    i = source.index(start)
    j = source.index(end, i) + len(end)
    return source[i:j]


def shared_parts() -> dict[str, str]:
    index = (SITE / "index.html").read_text(encoding="utf-8")
    parts = {
        "sprite": block(index, '<svg class="sprite"', "</svg>\n"),
        "header": block(index, '<header class="site-header"', "</header>"),
        "footer": block(index, '<footer class="site-footer">', "</footer>"),
        "dialog": block(index, '<dialog class="dl-modal"', "</dialog>"),
    }
    for key in ("header", "footer", "dialog"):
        text = parts[key]
        text = text.replace('href="#top"', 'href="../index.html"')
        text = re.sub(r'(<a\b[^>]*?\shref=)"#([\w-]+)"', r'\1"../index.html#\2"', text)
        text = text.replace('src="assets/', 'src="../assets/').replace('srcset="assets/', 'srcset="../assets/')
        text = re.sub(r'(\s)(assets/img/[\w.-]+ 2x)', r'\1../\2', text)
        # The home page's own links to the guides become links between guide pages.
        text = re.sub(r'href="docs/([\w-]+\.html)', r'href="\1', text)
        parts[key] = text
    parts["header"] = parts["header"].replace('<a href="../index.html#docs">Docs</a>', '<a href="../index.html#docs" aria-current="true">Docs</a>')
    return parts


def rewrite_link(href: str, source: str) -> str:
    """Links between guides stay on the site. Other repository files open on GitHub."""
    if re.match(r"^(?:[a-z][a-z0-9+.-]*:|#|//)", href, re.I):
        return href
    path, _, anchor = href.partition("#")
    if not path:
        return href
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(source), path))
    suffix = f"#{anchor}" if anchor else ""
    if resolved in PAGE_FOR_SOURCE:
        return f"{PAGE_FOR_SOURCE[resolved]}.html{suffix}"
    if resolved == "README.md":
        return f"../index.html{suffix}"
    kind = "tree" if (ROOT / resolved).is_dir() else "blob"
    return f"{REPO}/{kind}/main/{resolved}{suffix}"


DIAGRAM_BLOCK = re.compile(r"^<!--\s*diagram:\s*([\w-]+)\s*-->[ \t]*\n```mermaid[ \t]*\n.*?^```[ \t]*$", re.M | re.S)


def inline_svg(path: Path, cls: str) -> str:
    """The SVG file without its prolog, comments and preview style block, ready to inline."""
    svg = path.read_text(encoding="utf-8")
    svg = re.sub(r"<\?xml[^>]*\?>\s*", "", svg)
    svg = re.sub(r"<!--.*?-->\s*", "", svg, flags=re.S)
    svg = re.sub(r"\s*<style>.*?</style>", "", svg, flags=re.S)
    width = re.search(r'viewBox="0 0 ([\d.]+) ', svg)
    style = f' style="max-width: {width.group(1)}px"' if width else ""
    svg = re.sub(r'\s(width|height)="[\d.]+"', "", svg, count=2)
    return svg.replace("<svg ", f'<svg class="{cls}"{style} ', 1).strip()


def diagram_html(name: str, source: str) -> str:
    wide, narrow = DIAGRAMS / f"{name}.svg", DIAGRAMS / f"{name}-narrow.svg"
    if not wide.exists():
        sys.exit(f"{source}: diagram {name!r} has no {wide.relative_to(ROOT)}")
    if not narrow.exists():
        return f'<figure class="diagram">{inline_svg(wide, "diagram-svg")}</figure>'
    return (f'<figure class="diagram">{inline_svg(wide, "diagram-svg diagram-wide")}'
            f'{inline_svg(narrow, "diagram-svg diagram-narrow")}</figure>')


def take_diagrams(text: str, source: str) -> tuple[str, dict[str, str]]:
    """Swap each marked mermaid block for a placeholder paragraph and its inline SVG."""
    figures: dict[str, str] = {}

    def swap(m: re.Match) -> str:
        key = f"DECKDIAGRAM{len(figures)}"
        figures[key] = diagram_html(m.group(1), source)
        return key

    text = DIAGRAM_BLOCK.sub(swap, text)
    if "```mermaid" in text:
        print(f"warning: {source} has a mermaid block without a <!-- diagram: name --> line, shown as code")
    return text, figures


def postprocess(body: str, source: str) -> str:
    body = re.sub(r'href="([^"]+)"', lambda m: f'href="{html.escape(rewrite_link(html.unescape(m.group(1)), source), quote=True)}"', body)
    body = re.sub(r'<a href="(https?://[^"]+)"', r'<a href="\1" rel="noopener"', body)

    # Highlighted code blocks get a Copy button (site.js copies [data-copy-text]).
    def code(m: re.Match) -> str:
        inner = m.group(1)
        lang = ""
        lm = re.search(r'<code class="language-([\w+-]+)"', inner)
        if lm:
            lang = lm.group(1)
        inner = re.sub(r"<code(?: class=\"[^\"]*\")?>", "<code data-copy-text>", inner, count=1)
        inner = inner.replace("<span></span>", "")
        label = f'<span class="code-lang">{html.escape(lang)}</span>' if lang and lang not in ("text", "plain") else ""
        return f'<div class="code-block doc-code" data-copy-scope>{label}{inner}{COPY_BUTTON}</div>'

    body = re.sub(r'<div class="hl">(.*?)</div>', code, body, flags=re.S)
    # Short inline code (flags, file names) never breaks at a hyphen. Long code still wraps.
    body = re.sub(r"<code>([^<]{1,32})</code>", r'<code class="nw">\1</code>', body)
    body = re.sub(r"<table>", '<div class="table-scroll"><table>', body)
    body = body.replace("</table>", "</table></div>")
    return body


def toc_html(tokens: list[dict]) -> str:
    items = []

    def walk(nodes: list[dict], depth: int) -> None:
        for node in nodes:
            if node["level"] > 3:
                continue
            cls = "toc-sub" if node["level"] == 3 else ""
            items.append(f'<li class="{cls}"><a href="#{node["id"]}">{node["name"]}</a></li>')
            walk(node.get("children", []), depth + 1)

    for top in tokens:  # the H1 is the page title, list what is under it
        walk(top.get("children", []) if top["level"] == 1 else [top], 0)
    return "\n".join(items)


def first_paragraph(body: str) -> str:
    m = re.search(r"<p>(.*?)</p>", body, re.S)
    text = re.sub(r"<[^>]+>", "", m.group(1)) if m else ""
    text = html.unescape(re.sub(r"\s+", " ", text)).strip()
    if len(text) > 158:
        text = text[:155].rsplit(" ", 1)[0] + "..."
    return text


def render(source: str, name: str, label: str, parts: dict[str, str]) -> tuple[str, dt.date | None]:
    md = markdown.Markdown(
        extensions=["extra", "sane_lists", "toc", "codehilite"],
        extension_configs={
            "toc": {
                "permalink": "#",
                "permalink_class": "anchor",
                "permalink_title": "Link to this section",
                "toc_depth": "2-3",
                "slugify": slugify,
            },
            "codehilite": {"css_class": "hl", "guess_lang": False, "use_pygments": True},
        },
        output_format="html",
    )
    text, figures = take_diagrams((ROOT / source).read_text(encoding="utf-8"), source)
    body = md.convert(text)
    tokens = getattr(md, "toc_tokens", [])

    # The H1 becomes the page title block.
    title = label
    h1 = re.search(r"<h1[^>]*>(.*?)</h1>", body, re.S)
    if h1:
        title_html = re.sub(r'<a class="anchor"[^>]*>.*?</a>', "", h1.group(1)).strip()
        title = html.unescape(re.sub(r"<[^>]+>", "", title_html))
        body = body.replace(h1.group(0), "", 1)
    else:
        title_html = html.escape(title)
    body = postprocess(body, source)
    for key, figure in figures.items():
        body = body.replace(f"<p>{key}</p>", figure)
    description = first_paragraph(body) or f"{title}, a Container Deck guide."
    updated = git_date(source)
    toc = toc_html(tokens)

    guide_links = "\n".join(
        f'<li><a href="{n}.html"{" aria-current=\"page\"" if n == name else ""}>{html.escape(l)}</a></li>'
        for _, n, l in GUIDES
    )
    meta = []
    if updated:
        meta.append(f'<a href="{REPO}/commits/main/{source}">Last updated {human_date(updated)}</a>')
    meta.append(f'<a href="{REPO}/edit/main/{source}">Edit on GitHub</a>')
    meta_html = "".join(f"<li>{m}</li>" for m in meta)
    toc_block = f"""
        <nav class="doc-toc" aria-labelledby="toc-title">
          <details open>
            <summary id="toc-title">On this page</summary>
            <ol>
{toc}
            </ol>
          </details>
        </nav>""" if toc else ""

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)} · Container Deck</title>
  <meta name="description" content="{html.escape(description, quote=True)}">
  <link rel="canonical" href="{SITE_URL}docs/{name}.html">
  <meta name="color-scheme" content="light dark">
  <meta name="theme-color" content="#F4F3F0" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#0E0F12" media="(prefers-color-scheme: dark)">
  <meta property="og:type" content="article">
  <meta property="og:site_name" content="Container Deck">
  <meta property="og:title" content="{html.escape(title, quote=True)}">
  <meta property="og:description" content="{html.escape(description, quote=True)}">
  <meta property="og:url" content="{SITE_URL}docs/{name}.html">
  <meta property="og:image" content="{SITE_URL}assets/img/social-card.png">
  <meta name="twitter:card" content="summary_large_image">
  <link rel="icon" href="../favicon.ico" sizes="48x48">
  <link rel="icon" href="../favicon.svg" type="image/svg+xml">
  <link rel="apple-touch-icon" href="../apple-touch-icon.png">
  <script>
    (function () {{
      var d = document.documentElement;
      d.classList.add("js");
      try {{
        var t = localStorage.getItem("deck-theme");
        if (t === "light" || t === "dark") d.setAttribute("data-theme", t);
      }} catch (e) {{}}
    }})();
  </script>
  <link rel="stylesheet" href="../assets/css/site.css">
  <link rel="stylesheet" href="../assets/css/docs.css">
  <script src="../assets/js/site.js" defer></script>
</head>
<body class="doc-page">
  {parts["sprite"].strip()}

  <a class="skip-link" href="#main">Skip to content</a>

  {parts["header"]}

  <main id="main" class="wrap doc-layout">
    <aside class="doc-side" aria-label="Guides">
      <p class="doc-side-title">Guides</p>
      <ul class="doc-guides">
{guide_links}
      </ul>
    </aside>

    <article class="doc-article">
      <header class="doc-head">
        <p class="doc-crumbs"><a href="../index.html#docs">Docs</a><span aria-hidden="true">/</span>{html.escape(label)}</p>
        <h1>{title_html}</h1>
        <ul class="doc-meta">{meta_html}</ul>
      </header>
{toc_block.replace('class="doc-toc"', 'class="doc-toc doc-toc-inline"').replace('<details open>', '<details>').replace('aria-labelledby="toc-title"', 'aria-label="Contents"').replace(' id="toc-title"', '') if toc else ""}
      <div class="prose">
{body}
      </div>
      <footer class="doc-end">
        <a href="{REPO}/edit/main/{source}">Edit this page on GitHub</a>
        <a href="{REPO}/issues">Report a problem</a>
      </footer>
    </article>
{toc_block.replace('class="doc-toc"', 'class="doc-toc doc-toc-side"').replace('id="toc-title"', 'id="toc-title-side"').replace('aria-labelledby="toc-title"', 'aria-labelledby="toc-title-side"') if toc else ""}
  </main>

  {parts["footer"]}
{parts["dialog"]}
  <div class="sr-only" aria-live="polite" id="live"></div>
</body>
</html>
"""
    return page, updated


def write_sitemap(dates: dict[str, dt.date | None]) -> None:
    home = max((d for d in [git_date("website/index.html"), *dates.values()] if d), default=dt.date.today())
    urls = [(SITE_URL, home, "monthly", "1.0")]
    for _, name, _ in GUIDES:
        urls.append((f"{SITE_URL}docs/{name}.html", dates.get(name) or home, "monthly", "0.7"))
    rows = "\n".join(
        f"  <url>\n    <loc>{loc}</loc>\n    <lastmod>{day.isoformat()}</lastmod>\n"
        f"    <changefreq>{freq}</changefreq>\n    <priority>{prio}</priority>\n  </url>"
        for loc, day, freq, prio in urls
    )
    (SITE / "sitemap.xml").write_text(
        f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n{rows}\n</urlset>\n',
        encoding="utf-8",
    )


def main() -> None:
    parts = shared_parts()
    OUT.mkdir(parents=True, exist_ok=True)
    dates: dict[str, dt.date | None] = {}
    for source, name, label in GUIDES:
        page, updated = render(source, name, label, parts)
        (OUT / f"{name}.html").write_text(page, encoding="utf-8")
        dates[name] = updated
        print(f"docs/{name}.html  <-  {source}")
    write_sitemap(dates)
    print("sitemap.xml")


if __name__ == "__main__":
    main()
