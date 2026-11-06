# 📚 DocServer – lokale Context7-Alternative für Proxmox VE

DocServer indexiert Dokumentation (URLs, Sitemaps, Dateien) **vollständig lokal**
in einer SQLite-FTS5-Datenbank und stellt sie bereit als:

- **Web-UI** (durchsuchen, Libraries verwalten, Sync-Status)
- **REST-API** (`/api/search`)
- **MCP-Endpunkt** (`/mcp`, Context7-kompatible Tools `resolve-library-id` + `query-docs`)
  für ZCode, Cursor, Claude Desktop & Co.

Kein Cloud-Dienst, keine API-Kosten – alles läuft in einem LXC-Container auf deinem Proxmox-Host.

## 🚀 Installation (Einzeiler auf dem Proxmox-Host)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/proxmox-docserver/main/install/docserver.sh)"
```

Das Script:

- nimmt automatisch die **nächste freie CT-ID** (ab 100) und den Hostnamen `docserver`
- erstellt einen **unprivileged LXC** (Standard: 2 vCPU, 1 GB RAM, 4 GB Disk, `onboot: 1`)
- installiert Python + FastAPI in einer venv, richtet den **systemd-Dienst** ein
  (`Restart=always`, reboot-sicher) und
- **verifiziert** anschließend selbst: Dienst aktiv + Web-UI antwortet

Am Ende erscheint eine Zusammenfassung mit URL, MCP-Endpunkt und Auth-Token.

### Optionen

```bash
bash docserver.sh --id 150 --cores 2 --memory 2048 --rootfs 8 \
     --ip 192.168.178.50/24 --gateway 192.168.178.1
```

| Option | Beschreibung |
|---|---|
| `--id ID` | feste Container-ID (Standard: nächste freie) |
| `--hostname NAME` | Hostname (Standard: `docserver`) |
| `--storage NAME` | Storage (Standard: `local-lvm`) |
| `--rootfs GB` / `--cores N` / `--memory MB` / `--swap MB` | Ressourcen |
| `--ip IP/NET` + `--gateway IP` | statische IP (Standard: DHCP) |
| `--password PW` | Container-Root-Passwort (Standard: `docserver`) |
| `--local` | App-Dateien aus lokalem `docserver-app/` statt GitHub |

## 🛠 Verwaltung

```bash
# Update der App in bestehendem Container
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/proxmox-docserver/main/install/docserver.sh)" -- --update --id <CT-ID>

# Status
… -- --status --id <CT-ID>

# Deinstallieren (Container + Daten löschen)
… -- --uninstall --id <CT-ID>

# Im Container
pct enter <CT-ID>
systemctl status docserver
journalctl -u docserver -f
```

> **Debugging:** Bei Fehlern komplettes Log mit `bash -x` erzeugen:
> `bash -x docserver.sh …`. Das Script gibt bei Fehlern Zeile, Exit-Code
> und relevante Log-Auszüge (journalctl) aus.

## 🤖 KI-Client einbinden

Die fertigen Copy-Paste-Snippets (ZCode/Cursor, Claude Desktop, curl) stehen
nach der Installation unter `http://<CT-IP>:8080/setup`.

Universelles `mcpServers`-JSON:

```json
{
  "mcpServers": {
    "docserver": {
      "url": "http://<CT-IP>:8080/mcp",
      "headers": { "Authorization": "Bearer <TOKEN>" }
    }
  }
}
```

## 📖 Nutzung

1. `http://<CT-IP>:8080` öffnen → Library anlegen (z. B. `fastapi`)
2. In der Library Doku-URLs einfügen (eine pro Zeile) oder eine `sitemap.xml`
   (bis 50 Seiten automatisch) bzw. `.md/.txt/.html`-Dateien hochladen
3. Sync abwarten, dann in der Web-UI suchen – oder den Agent fragen

## 🔐 Sicherheit

- Der Installer generiert ein zufälliges **AUTH_TOKEN** (`/opt/docserver/config.env`):
  Web-UI per Passwort-Login, API/MCP per Bearer-Token.
- Für ein rein privates LAN kann der Token in `config.env` geleert werden
  (`AUTH_TOKEN=`, danach `systemctl restart docserver`) → offen ohne Login.

## Architektur

```
docserver-app/
├── app.py          FastAPI: Web-UI, REST, Auth, Sync-Worker
├── database.py     SQLite + FTS5 (BM25, Snippets)
├── crawler.py      httpx + BeautifulSoup: HTML→Abschnitte→Chunks, Sitemaps
├── mcp_server.py   FastMCP: resolve-library-id, query-docs → /mcp
├── config.py       Konfiguration (ENV)
└── templates/ static/   Jinja2-UI (dunkel, deutsch)
```

## Lizenz

MIT – siehe [LICENSE](LICENSE)
