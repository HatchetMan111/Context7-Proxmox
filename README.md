# 🚀 Context7 auf Proxmox VE (LXC)

Installiert den **offiziellen Context7-MCP-Server von Upstash**
([`@upstash/context7-mcp`](https://www.npmjs.com/package/@upstash/context7-mcp))
in einem LXC-Container auf deinem Proxmox-Host – als systemd-Dienst,
reboot-sicher, mit Einzeiler.

> Context7 liefert aktuelle Library-Dokumentation an KI-Clients (ZCode,
> Cursor, Claude Desktop, …) über das Model Context Protocol. Es gibt
> **keine Weboberfläche** – der Container stellt den MCP-Endpunkt bereit:
> `http://<CT-IP>:8080/mcp`

## 🚀 Installation (Einzeiler auf dem Proxmox-Host)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Context7-Proxmox/main/install/context7.sh)"
```

Das Script:

- nimmt automatisch die **nächste freie CT-ID** (ab 100) und den Hostnamen `context7`
- erstellt einen **unprivileged LXC** (Standard: 2 vCPU, 1 GB RAM, 4 GB Disk, `onboot: 1`)
- installiert **Node.js 22** (NodeSource) und `@upstash/context7-mcp`
- richtet den **systemd-Dienst** ein (`Restart=always`, reboot-sicher)
- **verifiziert** sich selbst: Dienst aktiv + echter MCP-Handshake (JSON-RPC `initialize`)

### Optionen

```bash
bash context7.sh --id 150 --memory 2048 --ip 192.168.178.60/24 --gateway 192.168.178.1 \
     --api-key DEIN_CONTEXT7_KEY
```

| Option | Beschreibung |
|---|---|
| `--id ID` | feste Container-ID (Standard: nächste freie) |
| `--hostname NAME` | Hostname (Standard: `context7`) |
| `--storage NAME` | Storage (Standard: `local-lvm`) |
| `--rootfs GB` / `--cores N` / `--memory MB` / `--swap MB` | Ressourcen |
| `--ip IP/NET` + `--gateway IP` | statische IP (Standard: DHCP) |
| `--password PW` | Container-Root-Passwort (Standard: `context7`) |
| `--port PORT` | MCP-Port (Standard: `8080`) |
| `--api-key KEY` | Context7-API-Key – **erforderlich** (v4.x), kostenlos auf context7.com/dashboard |

## 🔑 API-Key (erforderlich)

Context7 **v4.x verlangt zwingend einen API-Key** – ohne Key antwortet der
Server mit `HTTP 401`. Einen kostenlosen Key gibt es auf
[context7.com/dashboard](https://context7.com/dashboard).

Direkt bei der Installation mitgeben: `--api-key DEIN_KEY` –
oder nachträglich eintragen:

```bash
pct enter <CT-ID>
nano /opt/context7/config.env      # CONTEXT7_API_KEY=...
systemctl restart context7
```

## 🤖 KI-Client verbinden

Universelles `mcpServers`-JSON (ZCode, Cursor, …):

```json
{
  "mcpServers": {
    "context7": {
      "url": "http://<CT-IP>:8080/mcp",
      "headers": { "Authorization": "Bearer DEIN_CONTEXT7_KEY" }
    }
  }
}
```

Claude Desktop → Einstellungen → Connectors → Remote MCP:
`http://<CT-IP>:8080/mcp` (+ Header `Authorization: Bearer <KEY>`, wenn Key gesetzt).

Die Tools heißen wie gewohnt `resolve-library-id` und `get-library-docs`.

## 🛠 Verwaltung

```bash
# MCP-Paket auf neuesten Stand + Neustart
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Context7-Proxmox/main/install/context7.sh)" -- --update --id <CT-ID>

# Status (Container + Dienst + MCP-Sonde)
… -- --status --id <CT-ID>

# Deinstallieren (Container löschen)
… -- --uninstall --id <CT-ID>

# Im Container
pct enter <CT-ID>
systemctl status context7
journalctl -u context7 -f
```

> **Debugging:** Bei Fehlern komplettes Log mit `bash -x` erzeugen:
> `bash -x context7.sh …`. Das Script gibt bei Fehlern Zeile, Exit-Code
> und relevante Log-Auszüge (journalctl) aus.

## Architektur

```
install/
├── context7.sh          Installer: LXC erstellen → Node.js 22 → npm-Paket → systemd
└── context7.service     systemd-Unit (EnvironmentFile=/opt/context7/config.env)
```

Der Container lädt die Dokumentation live über den Upstash-Backed-Dienst
(`mcp.context7.com`) – ein Internetzugang ist erforderlich.

## Lizenz

MIT – siehe [LICENSE](LICENSE)
