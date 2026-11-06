"""Abrufen und Extrahieren von Dokumentationsinhalten.

- HTML-Seiten: Hauptinhalt (<main>/<article>/#content), bereinigt um
  Navigation/Skripte, in Abschnitte mit Heading-Pfad gegliedert.
- Sitemaps: alle <loc>-URLs, gleicher Host, gecappt.
- Markdown/Text-Dateien: Rohinhalt.
Ergebnis: Liste von Chunk-Dicts (title, url, heading, content).
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from urllib.parse import urlparse

import httpx
from bs4 import BeautifulSoup, Comment

from config import FETCH_TIMEOUT, MAX_PAGES_PER_SOURCE, USER_AGENT

CHUNK_MAX = 1200
CHUNK_OVERLAP = 150

_STRIP_TAGS = ("script", "style", "noscript", "svg", "form", "iframe", "template")
_SHELL_TAGS = ("nav", "header", "footer", "aside")
_CONTENT_SELECTORS = ("main", "article", "#content", ".content", "#main", ".docs")


class FetchError(RuntimeError):
    pass


def fetch(url: str) -> httpx.Response:
    try:
        resp = httpx.get(
            url,
            timeout=FETCH_TIMEOUT,
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT, "Accept": "*/*"},
        )
        resp.raise_for_status()
        return resp
    except httpx.HTTPError as exc:
        raise FetchError(f"{type(exc).__name__}: {exc}") from exc


def _same_host(url_a: str, url_b: str) -> bool:
    return urlparse(url_a).netloc.lower() == urlparse(url_b).netloc.lower()


def extract_sitemap_urls(sitemap_url: str) -> list[str]:
    resp = fetch(sitemap_url)
    try:
        root = ET.fromstring(resp.content)
    except ET.ParseError as exc:
        raise FetchError(f"Sitemap kein gültiges XML: {exc}") from exc
    ns = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    urls: list[str] = []
    for loc in root.findall(".//sm:loc", ns) + root.findall(".//loc"):
        if loc.text and loc.text.strip():
            urls.append(loc.text.strip())
    # Nur Dokumentseiten, gleicher Host, dedupliziert, gecappt
    seen: set[str] = set()
    out: list[str] = []
    for u in urls:
        low = u.lower()
        if low.endswith((".xml", ".gz", ".zip", ".png", ".jpg", ".pdf", ".zip")):
            continue
        if not _same_host(u, sitemap_url):
            continue
        if u not in seen:
            seen.add(u)
            out.append(u)
        if len(out) >= MAX_PAGES_PER_SOURCE:
            break
    return out


def _heading_path(hierarchy: list[str]) -> str:
    return " › ".join(h for h in hierarchy if h)


def extract_sections(html: str, url: str) -> list[dict]:
    """Zerlegt eine HTML-Seite in Abschnitte (title, url, heading, content)."""
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup.find_all(_STRIP_TAGS):
        tag.decompose()
    for tag in soup.find_all(_SHELL_TAGS):
        tag.decompose()

    title = ""
    if soup.title and soup.title.get_text(strip=True):
        title = soup.title.get_text(strip=True)
    elif soup.h1:
        title = soup.h1.get_text(strip=True)

    container = None
    for sel in _CONTENT_SELECTORS:
        found = soup.select_one(sel)
        if found:
            container = found
            break
    if container is None:
        container = soup.body or soup

    sections: list[dict] = []
    current_heading: list[str] = []
    buf: list[str] = []

    def flush() -> None:
        text = "\n".join(buf).strip()
        if text and len(text) > 40:  # Rauschen wie einzelne Buttons ignorieren
            sections.append({
                "title": title,
                "url": url,
                "heading": _heading_path(current_heading),
                "content": text,
            })
        buf.clear()

    for el in container.descendants:
        if isinstance(el, Comment):
            continue
        if getattr(el, "name", None) in ("h1", "h2", "h3", "h4"):
            flush()
            level = int(el.name[1])
            text = el.get_text(" ", strip=True)
            if text:
                current_heading = current_heading[: level - 1] + [text]
        elif el.name is None:  # NavigableString
            txt = str(el).strip()
            if txt:
                buf.append(txt)
    flush()

    if not sections:  # Fallback: kompletter Text
        text = container.get_text("\n", strip=True)
        if text:
            sections.append({"title": title, "url": url, "heading": "", "content": text})
    return sections


def _split_long(text: str) -> list[str]:
    """Zerlegt langen Text in überlappende Chunks."""
    if len(text) <= CHUNK_MAX:
        return [text] if text.strip() else []
    out: list[str] = []
    start = 0
    while start < len(text):
        piece = text[start:start + CHUNK_MAX]
        if start + CHUNK_MAX < len(text):
            cut = piece.rfind("\n", CHUNK_OVERLAP)
            if cut > 0:
                piece = piece[:cut]
        piece = piece.strip()
        if piece:
            out.append(piece)
        start += max(len(piece) - CHUNK_OVERLAP, 1) if piece else CHUNK_MAX
    return out


def chunk_entries(sections: list[dict]) -> list[dict]:
    chunks: list[dict] = []
    for sec in sections:
        for piece in _split_long(sec["content"]):
            chunks.append({
                "title": sec["title"],
                "url": sec["url"],
                "heading": sec["heading"],
                "content": piece,
            })
    return chunks


def fetch_url_source(url: str) -> list[dict]:
    """Eine URL → Chunks. Erkennt Sitemaps anhand .xml-Endung."""
    if url.lower().endswith(".xml") or "sitemap" in urlparse(url).path.lower():
        urls = extract_sitemap_urls(url)
    else:
        urls = [url]
    chunks: list[dict] = []
    errors: list[str] = []
    for u in urls:
        try:
            resp = fetch(u)
            ctype = resp.headers.get("content-type", "")
            if "html" in ctype or resp.text[:512].lstrip().lower().startswith(("<!doctype", "<html")):
                sections = extract_sections(resp.text, u)
            else:  # Markdown, Text, JSON-Doku etc.
                text = resp.text
                sections = [{"title": u.rsplit("/", 1)[-1] or u, "url": u,
                             "heading": "", "content": text}] if text.strip() else []
            chunks.extend(chunk_entries(sections))
        except FetchError as exc:
            errors.append(f"{u}: {exc}")
    if not chunks and errors:
        raise FetchError("; ".join(errors[:3]))
    return chunks


def fetch_file_source(path: str, name: str) -> list[dict]:
    """Lokale Datei (Upload) → Chunks."""
    text = open(path, "r", encoding="utf-8", errors="replace").read()
    if not text.strip():
        return []
    sections = [{"title": name, "url": "", "heading": "", "content": text}]
    return chunk_entries(sections)
