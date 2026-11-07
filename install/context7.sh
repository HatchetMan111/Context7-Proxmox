#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  Context7 – offizieller Upstash-MCP-Server als Proxmox-LXC
#
#  Erstellt einen LXC-Container mit Node.js und dem offiziellen
#  @upstash/context7-mcp Server (HTTP-Transport) als systemd-Dienst.
#  Keine Weboberfläche – Context7 ist ein MCP-Endpunkt für KI-Clients
#  (ZCode, Cursor, Claude Desktop, …): http://<CT-IP>:8080/mcp
#
#  Einzeiler (auf dem Proxmox-Host):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Context7-Proxmox/main/install/context7.sh)"
#
#  Optionen:   bash context7.sh --help
#  Update:     bash context7.sh --update
#  Deinstall:  bash context7.sh --uninstall
#  Status:     bash context7.sh --status
#  Debug:      bash -x context7.sh   (vollständiges Kommando-Log)
# ═══════════════════════════════════════════════════════════════════════════
set -Eeuo pipefail

# ───────────────────────────── Variablen ───────────────────────────────────
REPO_RAW="https://raw.githubusercontent.com/HatchetMan111/Context7-Proxmox/main"
APP_NAME="context7"
SERVICE_NAME="context7"
APP_DIR="/opt/context7"
NODE_MAJOR=22                       # Node.js-Hauptversion (≥ 20.18.1 nötig)
MCP_PACKAGE="@upstash/context7-mcp"

CT_ID=""                    # leer = nächste freie ID (ab MIN_ID)
CT_HOSTNAME="context7"
CT_STORAGE="local-lvm"
CT_ROOTFS=4                 # GB
CT_CORES=2
CT_MEMORY=1024              # MB
CT_SWAP=0
CT_BRIDGE="vmbr0"
CT_IP="dhcp"                # z. B. 192.168.178.60/24
CT_GW=""                    # optional, z. B. 192.168.178.1
CT_PASSWORD="context7"
CT_TEMPLATE=""              # leer = automatisch finden
MIN_ID=100
APP_PORT=8080
CONTEXT7_API_KEY=""         # optional – höheres Rate-Limit (context7.com/dashboard)

MODE="install"
TMP_DIR=""

# ───────────────────────────── Log-Helfer ──────────────────────────────────
C_RESET='\033[0m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'; C_BLUE='\033[0;34m'; C_BOLD='\033[1m'
info()  { echo -e "${C_BLUE}ℹ ${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}✓ ${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}⚠ ${C_RESET} $*"; }
err()   { echo -e "${C_RED}✗ ${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }
header(){ echo -e "\n${C_BOLD}━━━ $* ━━━${C_RESET}"; }

# Vollständige Fehlerkette: Zeile + Exit-Code + Debug-Hinweis
trap 'rc=$?; err "Fehler (Exit-Code $rc) in Zeile $LINENO"; \
      err "Debug: wget -qLO /tmp/context7.sh ${REPO_RAW}/install/context7.sh && bash -x /tmp/context7.sh"; exit $rc' ERR

cleanup() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}" || true; }
trap cleanup EXIT

download_file() {  # download_file <url> <ziel>
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest" "$url"
  else
    wget -qO "$dest" "$url"
  fi
}

# ───────────────────────────── Argumente ───────────────────────────────────
usage() {
  cat <<EOF
Context7 (offizieller Upstash-MCP-Server) – Proxmox-LXC-Installer

Verwendung:
  bash context7.sh [OPTIONEN]

Installations-Optionen:
  --id ID            Container-ID (Standard: nächste freie ab ${MIN_ID})
  --hostname NAME    Hostname (Standard: ${CT_HOSTNAME})
  --storage NAME     Storage (Standard: ${CT_STORAGE})
  --rootfs GB        Disk-Größe (Standard: ${CT_ROOTFS})
  --cores N          vCPUs (Standard: ${CT_CORES})
  --memory MB        RAM in MB (Standard: ${CT_MEMORY})
  --swap MB          Swap (Standard: ${CT_SWAP})
  --bridge NAME      Netz-Bridge (Standard: ${CT_BRIDGE})
  --ip IP/NET        Statische IP, z. B. 192.168.178.60/24 (Standard: dhcp)
  --gateway IP       Gateway bei statischer IP
  --password PW      Container-Root-Passwort (Standard: ${CT_PASSWORD})
  --template DATEI   vzdump-Template (Standard: automatisch Debian 12)
  --port PORT        MCP-Port im Container (Standard: ${APP_PORT})
  --api-key KEY      Context7-API-Key (PFLICHT seit v4.x, kostenlos:
                     https://context7.com/dashboard;
                     auch nachträglich in /opt/context7/config.env setzbar)

Aktionen:
  --update           MCP-Server-Paket aktualisieren (npm latest) + Neustart
  --uninstall        Container stoppen und löschen
  --status           Status von Container + Dienst anzeigen
  --help             Diese Hilfe
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)        CT_ID="$2"; shift 2 ;;
      --hostname)  CT_HOSTNAME="$2"; shift 2 ;;
      --storage)   CT_STORAGE="$2"; shift 2 ;;
      --rootfs)    CT_ROOTFS="$2"; shift 2 ;;
      --cores)     CT_CORES="$2"; shift 2 ;;
      --memory)    CT_MEMORY="$2"; shift 2 ;;
      --swap)      CT_SWAP="$2"; shift 2 ;;
      --bridge)    CT_BRIDGE="$2"; shift 2 ;;
      --ip)        CT_IP="$2"; shift 2 ;;
      --gateway)   CT_GW="$2"; shift 2 ;;
      --password)  CT_PASSWORD="$2"; shift 2 ;;
      --template)  CT_TEMPLATE="$2"; shift 2 ;;
      --port)      APP_PORT="$2"; shift 2 ;;
      --api-key)   CONTEXT7_API_KEY="$2"; shift 2 ;;
      --update)    MODE="update"; shift ;;
      --uninstall) MODE="uninstall"; shift ;;
      --status)    MODE="status"; shift ;;
      --help|-h)   usage; exit 0 ;;
      *)           err "Unbekannte Option: $1"; usage; exit 1 ;;
    esac
  done
}

# ───────────────────────────── Voraussetzungen ─────────────────────────────
check_prerequisites() {
  header "Voraussetzungen prüfen"
  [[ $EUID -eq 0 ]] || die "Bitte als root ausführen (Proxmox-Host)."
  command -v pct   >/dev/null 2>&1 || die "'pct' nicht gefunden – nicht auf einem Proxmox-Host?"
  command -v pveam >/dev/null 2>&1 || die "'pveam' nicht gefunden – nicht auf einem Proxmox-Host?"
  ok "Läuft als root auf Proxmox VE"

  if [[ -z "${CT_TEMPLATE}" ]]; then
    # pveam-Zeile: "local:vztmpl/<datei>   <größe>" → nur den Dateinamen nehmen
    CT_TEMPLATE=$(pveam list local 2>/dev/null | grep -i 'debian-12-standard' | head -1 \
                  | awk '{print $1}' | awk -F/ '{print $NF}')
    if [[ -z "${CT_TEMPLATE}" ]]; then
      info "Kein Debian-12-Template vorhanden – lade herunter …"
      pveam update >/dev/null
      pveam download local debian-12-standard_12.12-1_amd64.tar.zst
      CT_TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"
    fi
  else
    CT_TEMPLATE=$(basename "${CT_TEMPLATE}")
  fi
  if [[ ! "${CT_TEMPLATE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "Ungültiger Template-Name: '${CT_TEMPLATE}' – bitte --template <datei> angeben."
  fi
  ok "Template: ${CT_TEMPLATE}"
}

next_free_id() {
  local used="" max="${MIN_ID}" id
  used+=$(pct list | awk 'NR>1 {print $1}')
  if command -v qm >/dev/null 2>&1; then
    used+=" $(qm list | awk 'NR>1 {print $1}')"
  fi
  for id in $used; do
    [[ "$id" =~ ^[0-9]+$ ]] && (( id >= max )) && max=$(( id + 1 ))
  done
  echo "$max"
}

find_ct_by_hostname() {
  pct list | awk -v hn="$CT_HOSTNAME" 'NR>1 && $2==hn {print $1; exit}'
}

ct_exists() {
  pct list | awk '{print $1}' | grep -qx "$1"
}

# ───────────────────────────── Container ───────────────────────────────────
create_container() {
  header "LXC-Container erstellen"
  if [[ -n "${CT_ID}" ]] && ct_exists "${CT_ID}"; then
    die "CT ${CT_ID} existiert bereits. Für Updates: ${0} --update --id ${CT_ID}"
  fi
  if [[ -z "${CT_ID}" ]]; then
    CT_ID=$(next_free_id)
    info "Nächste freie CT-ID: ${CT_ID}"
  fi

  info "Erstelle CT ${CT_ID} (${CT_HOSTNAME}): ${CT_CORES} vCPU · ${CT_MEMORY} MB RAM · ${CT_ROOTFS} GB …"
  local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
  [[ -n "${CT_GW}" ]] && net0+=",gw=${CT_GW}"

  pct create "$CT_ID" "local:vztmpl/${CT_TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --storage "$CT_STORAGE" \
    --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --net0 "$net0" \
    --password "$CT_PASSWORD" \
    --unprivileged 1 \
    --onboot 1 \
    --start 0 \
    --description "Context7 MCP-Server (Upstash) – installiert am $(date '+%Y-%m-%d %H:%M')"
  ok "Container ${CT_ID} erstellt (onboot: aktiv, unprivileged)"

  info "Starte Container …"
  pct start "$CT_ID"
  ok "Container läuft"
}

wait_for_network() {
  info "Warte auf Netzwerk im Container …"
  local tries=0
  until pct exec "$CT_ID" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do
    tries=$(( tries + 1 ))
    (( tries > 30 )) && die "Kein Netzwerk im Container nach 60 s – Bridge/IP prüfen."
    sleep 2
  done
  ok "Netzwerk erreichbar"
}

# ───────────────────────────── Installation ────────────────────────────────
install_in_container() {
  header "Node.js ${NODE_MAJOR} im Container installieren"
  pct exec "$CT_ID" -- bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg >/dev/null
    curl -fsSL https://deb.nodesource.com/setup_'"${NODE_MAJOR}"'.x | bash -
    apt-get install -y -qq nodejs >/dev/null
  '
  local node_version
  node_version=$(pct exec "$CT_ID" -- node --version)
  ok "Node.js ${node_version} installiert"

  header "Context7-MCP-Server installieren (${MCP_PACKAGE})"
  pct exec "$CT_ID" -- bash -c "
    set -euo pipefail
    mkdir -p ${APP_DIR}
    npm install --prefix ${APP_DIR} --no-audit --no-fund ${MCP_PACKAGE}
    ${APP_DIR}/node_modules/.bin/context7-mcp --version 2>/dev/null || true
  "
  ok "Context7-MCP-Server installiert"
}

configure_service() {
  header "Dienst konfigurieren"
  local env_src="${TMP_DIR}/config.env"
  cat > "$env_src" <<EOF
PORT=${APP_PORT}
CONTEXT7_API_KEY=${CONTEXT7_API_KEY}
EOF
  pct push "$CT_ID" "$env_src" "${APP_DIR}/config.env" >/dev/null

  local unit_src="${TMP_DIR}/context7.service"
  download_file "${REPO_RAW}/install/context7.service" "$unit_src" \
    || die "Download der systemd-Unit fehlgeschlagen."
  pct push "$CT_ID" "$unit_src" "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null

  pct exec "$CT_ID" -- systemctl daemon-reload
  pct exec "$CT_ID" -- systemctl enable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    || pct exec "$CT_ID" -- systemctl restart "${SERVICE_NAME}.service"
  ok "systemd-Dienst aktiviert (Restart=always, After=network-online.target)"
}

# Echte MCP-Handshake-Sonde: JSON-RPC initialize gegen /mcp
mcp_probe() {  # mcp_probe  (läuft im Container-Kontext)
  local auth=()
  [[ -n "${CONTEXT7_API_KEY}" ]] && auth=(-H "Authorization: Bearer ${CONTEXT7_API_KEY}")
  pct exec "$CT_ID" -- curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
    -X POST "http://localhost:${APP_PORT}/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    ${auth[@]+"${auth[@]}"} \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install-probe","version":"1.0"}}}' || echo "000"
}

verify_installation() {
  header "Installation verifizieren"
  local state
  state=$(pct exec "$CT_ID" -- systemctl is-active "${SERVICE_NAME}")
  [[ "$state" == "active" ]] || {
    pct exec "$CT_ID" -- journalctl -u "${SERVICE_NAME}" -n 30 --no-pager || true
    die "Dienst ist nicht aktiv (Status: ${state})."
  }
  ok "Dienst läuft (systemctl is-active: active)"

  local tries=0 code=""
  info "Prüfe MCP-Endpunkt (JSON-RPC initialize) …"
  until [[ "${code}" =~ ^2|^4[0-9][0-9]$ ]]; do
    code=$(mcp_probe)
    tries=$(( tries + 1 ))
    (( tries > 20 )) && {
      pct exec "$CT_ID" -- journalctl -u "${SERVICE_NAME}" -n 30 --no-pager || true
      die "MCP-Endpunkt antwortet nicht auf Port ${APP_PORT}."
    }
    [[ "${code}" =~ ^2 ]] || sleep 1.5
  done
  ok "MCP-Endpunkt antwortet (HTTP ${code} auf /mcp)"

  if [[ -z "${CONTEXT7_API_KEY}" ]] || [[ "${code}" != 2* ]]; then
    warn "Context7 v4.x benötigt zwingend einen API-Key (ohne Key: HTTP 401)."
    warn "1) Kostenlosen Key erstellen: https://context7.com/dashboard"
    warn "2) Eintragen:  pct enter ${CT_ID}  →  nano ${APP_DIR}/config.env"
    warn "   (CONTEXT7_API_KEY=... )  →  systemctl restart ${SERVICE_NAME}"
    warn "   oder bei Installation:  --api-key DEIN_KEY"
  else
    ok "API-Key gesetzt (Bearer-Auth gegen /mcp aktiv)."
  fi
}

get_ct_ip() {
  if [[ "${CT_IP}" == "dhcp" ]]; then
    pct exec "$CT_ID" -- hostname -I | awk '{print $1}'
  else
    echo "${CT_IP%%/*}"
  fi
}

print_summary() {
  local ct_ip
  ct_ip=$(get_ct_ip)
  echo
  echo -e "${C_GREEN}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo -e "${C_GREEN}  🚀 Context7 MCP-Server erfolgreich installiert!${C_RESET}"
  echo -e "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo -e "  Container      : CT ${CT_ID} (${CT_HOSTNAME}, onboot)"
  echo -e "  MCP-Endpunkt   : ${C_BOLD}http://${ct_ip}:${APP_PORT}/mcp${C_RESET}"
  [[ -n "${CONTEXT7_API_KEY}" ]] \
    && echo -e "  API-Key        : gesetzt" \
    || echo -e "  API-Key        : ${C_RED}FEHLT – Clients erhalten HTTP 401!${C_RESET}"
  echo -e ""
  echo -e "  Client-Config (mcpServers-JSON):"
  echo -e "  {"
  echo -e "    \"mcpServers\": {"
  echo -e "      \"context7\": { \"url\": \"http://${ct_ip}:${APP_PORT}/mcp\","
  echo -e "        \"headers\": { \"Authorization\": \"Bearer ${CONTEXT7_API_KEY:-DEIN_CONTEXT7_KEY}\" }"
  echo -e "      }"
  echo -e "    }"
  echo -e "  }"
  echo -e ""
  echo -e "  Ins Terminal   : pct enter ${CT_ID}"
  echo -e "  Update später  : ${0} --update --id ${CT_ID}"
  echo -e "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
}

# ───────────────────────────── Weitere Modi ────────────────────────────────
resolve_existing_ct() {
  if [[ -n "${CT_ID}" ]] && ct_exists "${CT_ID}"; then
    return
  fi
  CT_ID=$(find_ct_by_hostname)
  [[ -n "${CT_ID}" ]] || die "Kein Container mit Hostname '${CT_HOSTNAME}' gefunden und keine --id angegeben."
}

do_update() {
  header "Update: Context7-MCP-Server"
  resolve_existing_ct
  if [[ "$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
    info "Container ist gestoppt – starte …"
    pct start "$CT_ID"
  fi
  install_in_container
  pct exec "$CT_ID" -- systemctl restart "${SERVICE_NAME}"
  verify_installation
  print_summary
}

do_uninstall() {
  header "Deinstallation: Context7"
  resolve_existing_ct
  warn "CT ${CT_ID} (${CT_HOSTNAME}) wird GESTOPPT und GELÖSCHT!"
  read -r -p "Wirklich löschen? [y/N] " confirm
  [[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || die "Abgebrochen."
  pct stop "$CT_ID" 2>/dev/null || true
  pct destroy "$CT_ID" --purge
  ok "Container ${CT_ID} entfernt."
}

do_status() {
  header "Status: Context7"
  resolve_existing_ct
  pct status "$CT_ID"
  pct exec "$CT_ID" -- systemctl is-active "${SERVICE_NAME}" || true
  local ct_ip code
  ct_ip=$(get_ct_ip)
  code=$(mcp_probe)
  if [[ "${code}" =~ ^2 ]]; then
    ok "MCP-Endpunkt erreichbar: http://${ct_ip}:${APP_PORT}/mcp (HTTP ${code})"
  else
    warn "MCP-Endpunkt antwortet nicht (HTTP ${code:-keine Antwort})."
  fi
}

# ───────────────────────────── Hauptablauf ─────────────────────────────────
main() {
  parse_args "$@"
  [[ $EUID -eq 0 ]] || die "Bitte als root ausführen (Proxmox-Host)."
  case "${MODE}" in
    install)
      echo -e "${C_BOLD}🚀 Context7 MCP-Server (Upstash) – Proxmox-LXC-Installer${C_RESET}"
      check_prerequisites
      create_container
      wait_for_network
      install_in_container
      configure_service
      verify_installation
      print_summary
      ;;
    update)    do_update ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
  esac
}

main "$@"
