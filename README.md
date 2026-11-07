# 🚀 Context7 auf Proxmox VE (LXC)

Installiert den **offiziellen Context7-MCP-Server von Upstash**
([`@upstash/context7-mcp`](https://www.npmjs.com/package/@upstash/context7-mcp))
in einem LXC-Container auf deinem Proxmox-Host – als systemd-Dienst,
reboot-sicher, mit Einzeiler.

> Context7 liefert aktuelle Library-Dokumentation an KI-Clients (ZCode,
> Cursor, Claude Desktop, …) über das Model Context Protocol. Es gibt
> **keine Weboberfläche** – der Container stellt den MCP-Endpunkt bereit:
> `http://<CT-IP>:8080/mcp`

## 🧠 Wie funktioniert Context7?

KI-Modelle kennen Bibliotheken nur bis zu ihrem Trainingsstand – sie erfinden
deshalb gern APIs, die so nicht (mehr) existieren. Context7 löst das, indem es
**aktuelle Dokumentation zur Laufzeit** in den Kontext des Agenten einspeist:

1. **Upstash crawlt** laufend offizielle Doku-Seiten und Repos und hält daraus
   einen sauberen, snippethaltigen Index. (Dieser Crawler/Index ist
   Upstash' Cloud-Backend und **nicht** Teil dieses Repos.)
2. Dein KI-Client (ZCode, Cursor, Claude Desktop, …) verbindet sich per **MCP**
   (Model Context Protocol, Streamable HTTP) mit diesem Container:
   `http://<CT-IP>:8080/mcp`
3. Braucht der Agent Doku, ruft er zuerst das Tool **`resolve-library-id`**
   auf (z. B. mit „react") und erhält passende Context7-Library-IDs wie
   `/reactjs/react.dev` – inklusive Beschreibung und Benchmark-Score.
4. Anschließend ruft er **`query-docs`** (Library-ID + Thema) auf und bekommt
   fokussierte Doku-Abschnitte mit Codebeispielen zurück.
5. Der Agent schreibt mit dieser frischen Doku korrekten Code, statt APIs zu
   raten.

```
KI-Client (ZCode / Cursor / Claude)
   │   MCP über HTTP (JSON-RPC, Streamable)
   ▼
LXC „context7" (dieser Container: Node.js + systemd)
   │   HTTPS → mcp.context7.com
   ▼
Upstash-Cloud (Doku-Index + Crawler)
```

Der Container ist also eine schlanke MCP-Zugangsstelle im LAN: Er speichert
**keine Dokumentation lokal**, sondern reicht Anfragen live an Upstash weiter
(Internetzugang nötig). Ohne API-Key arbeitet er anonym
(`MCP_AUTH_ENFORCEMENT=observe`, von Upstash gedrosselt); mit Key
(`--api-key` bzw. `config.env`) gibt es höhere Limits.

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

Mit Optionen (z. B. API-Key) am einfachsten in zwei Schritten:

```bash
wget -qLO /tmp/context7.sh https://raw.githubusercontent.com/HatchetMan111/Context7-Proxmox/main/install/context7.sh
bash /tmp/context7.sh --api-key DEIN_CONTEXT7_KEY
```

oder direkt (Einzeiler mit Argumenten):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Context7-Proxmox/main/install/context7.sh)" installer --api-key DEIN_CONTEXT7_KEY
```

Weitere Optionen:

```bash
bash /tmp/context7.sh --id 150 --memory 2048 --ip 192.168.178.60/24 --gateway 192.168.178.1
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
| `--api-key KEY` | Context7-API-Key – optional (anonymer Modus ohne Key, gedrosselt) |

## 🔑 API-Key (optional)

Der Server läuft **ohne Key** im anonymen Modus
(`MCP_AUTH_ENFORCEMENT=observe` in `/opt/context7/config.env`) – von Upstash
jedoch gedrosselt. Für höhere Limits einen kostenlosen Key auf
[context7.com/dashboard](https://context7.com/dashboard) holen und entweder
bei der Installation mitgeben (`--api-key DEIN_KEY`) oder nachträglich
eintragen:

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

Die Tools heißen wie gewohnt `resolve-library-id` und `query-docs`.

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
