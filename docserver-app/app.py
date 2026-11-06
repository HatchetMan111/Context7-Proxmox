"""DocServer – lokale Context7-Alternative.

FastAPI-Anwendung mit Web-UI, REST-API und MCP-Endpunkt (Streamable HTTP).
Start im LXC über systemd:  uvicorn app:app --host 0.0.0.0 --port $PORT
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import re
import threading
import traceback
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated
from urllib.parse import quote

import config
import crawler
import database as db
from mcp_server import mcp
from fastapi import (BackgroundTasks, FastAPI, File, Form, Request, Response,
                     UploadFile)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

APP_VERSION = "1.0.0"
SESSION_COOKIE = "docserver_session"
UPLOAD_DIR = Path(config.DATA_DIR) / "uploads"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("docserver")


# ------------------------------------------------------------------ Sync-Worker

# Claim pro Quelle (verhindert doppelte/gleichzeitige Syncs derselben Quelle)
_sources_mutex = threading.Lock()
_active_sources: set[int] = set()
# Guard pro Library (verhindert überlappende Voll-Syncs)
_sync_mutex = threading.Lock()
_active_libraries: set[int] = set()


def _claim_source(source_id: int) -> bool:
    with _sources_mutex:
        if source_id in _active_sources:
            return False
        _active_sources.add(source_id)
        return True


def _release_source(source_id: int) -> None:
    with _sources_mutex:
        _active_sources.discard(source_id)


def sync_source(source_id: int, src=None) -> None:
    """Synced eine Quelle und aktualisiert Status/Fehler in der DB."""
    src = src if src is not None else db.get_source(source_id)
    if src is None or not _claim_source(source_id):
        return
    try:
        db.set_source_status(src["id"], "syncing")
        try:
            if src["type"] == "file":
                path = UPLOAD_DIR / src["location"]
                entries = crawler.fetch_file_source(str(path), src["location"])
            else:
                entries = crawler.fetch_url_source(src["location"])
            db.replace_source_chunks(src["id"], src["library_id"], entries)
            db.set_source_status(src["id"], "ok", pages=len(entries))
            log.info("Quelle %s OK: %s Chunks", src["id"], len(entries))
        except Exception:
            err = traceback.format_exc(limit=6)
            log.error("Quelle %s fehlgeschlagen:\n%s", src["id"], err)
            db.set_source_status(src["id"], "error", error=err[-800:])
    finally:
        _release_source(source_id)


def sync_library(library_id: int) -> None:
    """Synced alle Quellen einer Library sequenziell (eine Instanz pro Library)."""
    with _sync_mutex:
        if library_id in _active_libraries:
            return
        _active_libraries.add(library_id)
    try:
        for src in db.list_sources(library_id):
            sync_source(src["id"], src)
    finally:
        with _sync_mutex:
            _active_libraries.discard(library_id)


def sync_source_bg(source_id: int) -> None:
    sync_source(source_id)


# ------------------------------------------------------------------ App-Setup

@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    # MCP-Session-Manager über die Haupt-App-Laufzeit laufen lassen
    # (Sub-App-Mount führt dessen Lifespan nicht selbst aus).
    sm = mcp.session_manager  # Property (neuere SDKs) oder Methode (ältere)
    mcp_ctx = sm.run() if not callable(sm) else sm()
    async with mcp_ctx:
        log.info("DocServer %s gestartet (DB: %s)", APP_VERSION, db.DB_PATH)
        yield


app = FastAPI(title="DocServer", version=APP_VERSION, lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["*"],
    expose_headers=["*"],
)

templates = Jinja2Templates(directory="templates")
templates.env.globals["auth_enabled"] = bool(config.AUTH_TOKEN)
app.mount("/static", StaticFiles(directory="static"), name="static")


# ------------------------------------------------------------------ Auth

def _session_value() -> str:
    return hmac.new(config.AUTH_TOKEN.encode(), b"docserver-session",
                    hashlib.sha256).hexdigest()


@app.middleware("http")
async def auth_middleware(request: Request, call_next):
    if not config.AUTH_TOKEN:
        return await call_next(request)
    path = request.url.path
    if (path == "/login" or path == "/api/health" or path == "/favicon.ico"
            or path.startswith("/static")):
        return await call_next(request)
    if request.headers.get("authorization") == f"Bearer {config.AUTH_TOKEN}":
        return await call_next(request)
    if request.cookies.get(SESSION_COOKIE) == _session_value():
        return await call_next(request)
    if request.method == "GET" and "text/html" in request.headers.get("accept", ""):
        return RedirectResponse(f"/login?next={quote(path)}", status_code=303)
    return JSONResponse({"error": "unauthorized – Bearer-Token oder Login nötig"},
                        status_code=401)


@app.get("/favicon.ico", include_in_schema=False)
async def favicon() -> Response:
    return Response(status_code=204)


# ------------------------------------------------------------------ Web-UI

@app.get("/login", response_class=HTMLResponse)
async def login_form(request: Request, next: str = "/"):
    return templates.TemplateResponse(request, "login.html",
                                      {"next": next, "error": ""})


@app.post("/login")
async def login_submit(request: Request, password: str = Form(""),
                       next: str = Form("/")):
    # next nur für interne Pfade erlauben (kein Open Redirect)
    if not next.startswith("/") or next.startswith("//"):
        next = "/"
    if hmac.compare_digest(password, config.AUTH_TOKEN):
        resp = RedirectResponse(next, status_code=303)
        resp.set_cookie(SESSION_COOKIE, _session_value(),
                        max_age=7 * 24 * 3600, httponly=True, samesite="lax")
        return resp
    return templates.TemplateResponse(request, "login.html",
                                      {"next": next, "error": "Falsches Passwort."},
                                      status_code=401)


@app.get("/logout")
async def logout() -> RedirectResponse:
    resp = RedirectResponse("/login", status_code=303)
    resp.delete_cookie(SESSION_COOKIE)
    return resp


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse(request, "index.html", {
        "libraries": db.list_libraries(),
        "total_chunks": db.count_chunks(),
    })


@app.post("/libraries")
async def create_library(name: str = Form(""), description: str = Form("")):
    name = name.strip()
    if name:
        if db.get_library_by_name(name) is None:
            db.add_library(name, description)
    return RedirectResponse("/", status_code=303)


@app.post("/libraries/{library_id}/delete")
async def delete_library(library_id: int):
    db.delete_library(library_id)
    return RedirectResponse("/", status_code=303)


@app.get("/library/{library_id}", response_class=HTMLResponse)
async def library_page(request: Request, library_id: int):
    lib = db.get_library(library_id)
    if lib is None:
        return RedirectResponse("/", status_code=303)
    return templates.TemplateResponse(request, "library.html", {
        "lib": lib,
        "sources": db.list_sources(library_id),
        "chunks": db.count_chunks(library_id),
    })


@app.post("/library/{library_id}/sources")
async def add_url_source(request: Request, library_id: int,
                         background: BackgroundTasks, url: str = Form("")):
    if db.get_library(library_id) is None:
        return RedirectResponse("/", status_code=303)
    new_ids = _add_url_sources(library_id, url)
    for sid in new_ids:
        background.add_task(sync_source_bg, sid)
    return RedirectResponse(f"/library/{library_id}", status_code=303)


@app.post("/library/{library_id}/upload")
async def upload_file(library_id: int, background: BackgroundTasks,
                      file: UploadFile = File(...)):
    if db.get_library(library_id) is None:
        return RedirectResponse("/", status_code=303)
    safe_name = re.sub(r"[^\w.\- ]", "_", Path(file.filename or "").name) or "upload.txt"
    dest = UPLOAD_DIR / safe_name
    dest.write_bytes(await file.read())
    sid = db.add_source(library_id, "file", safe_name)
    background.add_task(sync_source_bg, sid)
    return RedirectResponse(f"/library/{library_id}", status_code=303)


@app.post("/sources/{source_id}/delete")
async def delete_source(source_id: int):
    src = db.get_source(source_id)
    db.delete_source(source_id)
    if src:
        return RedirectResponse(f"/library/{src['library_id']}", status_code=303)
    return RedirectResponse("/", status_code=303)


@app.post("/sources/{source_id}/sync")
async def resync_source(source_id: int, background: BackgroundTasks):
    src = db.get_source(source_id)
    if src:
        background.add_task(sync_source_bg, source_id)
        return RedirectResponse(f"/library/{src['library_id']}", status_code=303)
    return RedirectResponse("/", status_code=303)


@app.post("/library/{library_id}/sync")
async def resync_library(library_id: int, background: BackgroundTasks):
    if db.get_library(library_id):
        background.add_task(sync_library, library_id)
        return RedirectResponse(f"/library/{library_id}", status_code=303)
    return RedirectResponse("/", status_code=303)


@app.get("/search", response_class=HTMLResponse)
async def search_page(request: Request, q: str = "", library: str = ""):
    lib_id = int(library) if library.isdigit() else None
    results = db.search(q, library_id=lib_id) if q.strip() else []
    return templates.TemplateResponse(request, "search.html", {
        "q": q, "results": results, "libraries": db.list_libraries(),
        "selected": lib_id,
    })


@app.get("/setup", response_class=HTMLResponse)
async def setup_page(request: Request):
    base = str(request.base_url).rstrip("/")
    return templates.TemplateResponse(request, "setup.html", {
        "base_url": base,
        "token": config.AUTH_TOKEN,
        "auth_enabled": bool(config.AUTH_TOKEN),
    })


# ------------------------------------------------------------------ REST-API

@app.get("/api/health")
async def health():
    return {
        "status": "ok",
        "version": APP_VERSION,
        "libraries": len(db.list_libraries()),
        "chunks": db.count_chunks(),
    }


def _add_url_sources(library_id: int, raw: str) -> list[int]:
    """Mehrere URLs (eine pro Zeile) erlauben; Typ auto-erkennen."""
    ids: list[int] = []
    for line in (raw or "").splitlines():
        url = line.strip()
        if not url or not re.match(r"^https?://", url):
            continue
        kind = "sitemap" if (url.lower().endswith(".xml")
                             or "sitemap" in url.lower()) else "url"
        ids.append(db.add_source(library_id, kind, url))
    return ids


@app.get("/api/libraries")
async def api_libraries():
    return [dict(lib) for lib in db.list_libraries()]


@app.post("/api/libraries", status_code=201)
async def api_create_library(name: str = Form(""), description: str = Form("")):
    name = name.strip()
    if not name:
        return JSONResponse({"error": "name erforderlich"}, status_code=422)
    if db.get_library_by_name(name) is not None:
        return JSONResponse({"error": f"Library '{name}' existiert bereits"},
                            status_code=409)
    lib_id = db.add_library(name, description)
    return {"id": lib_id, "name": name}


@app.delete("/api/libraries/{library_id}")
async def api_delete_library(library_id: int):
    if db.get_library(library_id) is None:
        return JSONResponse({"error": "Library nicht gefunden"}, status_code=404)
    db.delete_library(library_id)
    return {"status": "deleted", "id": library_id}


@app.post("/api/libraries/{library_id}/sources", status_code=202)
async def api_add_source(library_id: int, background: BackgroundTasks,
                         url: str = Form("")):
    if db.get_library(library_id) is None:
        return JSONResponse({"error": "Library nicht gefunden"}, status_code=404)
    new_ids = _add_url_sources(library_id, url)
    if not new_ids:
        return JSONResponse(
            {"error": "keine gültige URL (http(s)://) übergeben"}, status_code=422)
    for sid in new_ids:
        background.add_task(sync_source_bg, sid)
    return {"status": "syncing", "source_ids": new_ids}


@app.post("/api/sync/{library_id}", status_code=202)
async def api_sync_library(library_id: int, background: BackgroundTasks):
    if db.get_library(library_id) is None:
        return JSONResponse({"error": "Library nicht gefunden"}, status_code=404)
    background.add_task(sync_library, library_id)
    return {"status": "syncing", "library_id": library_id}


@app.get("/api/search")
async def api_search(q: str = "", library: str = "", limit: int = 12):
    lib_id = int(library) if library.isdigit() else None
    if lib_id is not None and db.get_library(lib_id) is None:
        return JSONResponse({"error": "Library nicht gefunden"}, status_code=404)
    return {
        "query": q,
        "results": db.search(q, library_id=lib_id, limit=max(1, min(limit, 50))),
    }


# MCP-Endpunkt (Streamable HTTP) – Mount zuletzt, fängt nur unbelegte Pfade.
app.mount("/", mcp.streamable_http_app())
