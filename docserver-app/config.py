"""Zentrale Konfiguration per Umgebungsvariablen (gesetzt aus config.env)."""

import os
from pathlib import Path

# Arbeitsverzeichnis der App (im LXC: /opt/docserver/app)
APP_DIR = Path(__file__).resolve().parent

# Datenverzeichnis (DB, Uploads) – per DOCSERVER_DATA_DIR übersteuerbar
DATA_DIR = Path(os.environ.get("DOCSERVER_DATA_DIR", APP_DIR / "data"))

# Leerer AUTH_TOKEN = offen (reines LAN). Sonst: Session-Cookie + Bearer nötig.
AUTH_TOKEN = os.environ.get("AUTH_TOKEN", "").strip()

PORT = int(os.environ.get("PORT", "8080"))

# Crawler-Limits
MAX_PAGES_PER_SOURCE = int(os.environ.get("MAX_PAGES", "50"))
FETCH_TIMEOUT = 20.0
USER_AGENT = "DocServer/1.0 (lokaler Dokumentationsindex; +https://github.com/HatchetMan111/Context7-Proxmox)"
