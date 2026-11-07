#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  DocServer – lokale Context7-Alternative für Proxmox VE
#
#  Erstellt einen LXC-Container, installiert FastAPI-App + Web-UI + MCP-
#  Endpunkt und richtet einen systemd-Dienst ein (reboot-sicher).
#
#  Einzeiler (auf dem Proxmox-Host):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Context7-Proxmox/main/install/docserver.sh)"
#
#  Optionen:   bash docserver.sh --help
#  Update:     bash docserver.sh --update
#  Deinstall:  bash docserver.sh --uninstall
#  Status:     bash docserver.sh --status
#  Debug:      bash -x docserver.sh   (vollständiges Kommando-Log)
# ═══════════════════════════════════════════════════════════════════════════
set -Eeuo pipefail

# ───────────────────────────── Variablen ───────────────────────────────────
REPO_RAW="https://raw.githubusercontent.com/HatchetMan111/Context7-Proxmox/main"
APP_NAME="docserver"
SERVICE_NAME="docserver"
APP_DIR="/opt/docserver"

CT_ID=""                    # leer = nächste freie ID (ab MIN_ID)
CT_HOSTNAME="docserver"
CT_STORAGE="local-lvm"
CT_ROOTFS=4                 # GB
CT_CORES=2
CT_MEMORY=1024              # MB
CT_SWAP=0
CT_BRIDGE="vmbr0"
CT_IP="dhcp"                # z. B. 192.168.178.50/24
CT_GW=""                    # optional, z. B. 192.168.178.1
CT_PASSWORD="docserver"
CT_TEMPLATE=""              # leer = automatisch finden
MIN_ID=100
APP_PORT=8080

MODE="install"              # install | update | uninstall | status
LOCAL_MODE=false
APP_SRC=""
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
trap 'rc=$?; err "Fehler (Exit-Code $rc) in Zeile $LINENO von $0"; \
      err "Vollständiges Debug-Log:  bash -x $0 $*"; exit $rc' ERR

cleanup() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}" || true; }
trap cleanup EXIT

# ───────────────────────────── Download ────────────────────────────────────
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
DocServer – Proxmox-LXC-Installer (lokale Context7-Alternative)

Verwendung:
  bash docserver.sh [OPTIONEN]

Installations-Optionen:
  --id ID            Container-ID (Standard: nächste freie ab ${MIN_ID})
  --hostname NAME    Hostname (Standard: ${CT_HOSTNAME})
  --storage NAME     Storage (Standard: ${CT_STORAGE})
  --rootfs GB        Disk-Größe (Standard: ${CT_ROOTFS})
  --cores N          vCPUs (Standard: ${CT_CORES})
  --memory MB        RAM in MB (Standard: ${CT_MEMORY})
  --swap MB          Swap (Standard: ${CT_SWAP})
  --bridge NAME      Netz-Bridge (Standard: ${CT_BRIDGE})
  --ip IP/NET        Statische IP, z. B. 192.168.178.50/24 (Standard: dhcp)
  --gateway IP       Gateway bei statischer IP
  --password PW      Container-Root-Passwort (Standard: ${CT_PASSWORD})
  --template DATEI   vzdump-Template (Standard: automatisch Debian 12)
  --local            App-Dateien aus docserver-app/ neben diesem Script
                     verwenden (statt aus GitHub zu laden)

Aktionen:
  --update           App-Dateien in bestehendem Container aktualisieren
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
      --local)     LOCAL_MODE=true; shift ;;
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
    CT_TEMPLATE=$(pveam list local 2>/dev/null | grep -i 'debian-12-standard' | head -1 | awk -F/ '{print $2}')
    if [[ -z "${CT_TEMPLATE}" ]]; then
      info "Kein Debian-12-Template vorhanden – lade herunter …"
      pveam update >/dev/null
      pveam download local debian-12-standard_12.12-1_amd64.tar.zst
      CT_TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"
    fi
    ok "Template: ${CT_TEMPLATE}"
  else
    ok "Template (per Option): ${CT_TEMPLATE}"
  fi
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

# ───────────────────────────── App-Dateien ─────────────────────────────────
download_app() {
  header "App-Dateien vorbereiten"
  TMP_DIR=$(mktemp -d)
  APP_SRC="${TMP_DIR}/app"
  mkdir -p "${APP_SRC}/templates" "${APP_SRC}/static"

  if ${LOCAL_MODE}; then
    local base
    base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -d "${base}/docserver-app" ]] || die "docserver-app/ nicht neben dem Script gefunden."
    cp -r "${base}/docserver-app/." "${APP_SRC}/"
    ok "Lokale Quellen kopiert: ${base}/docserver-app"
  else
    local files=(
      "app.py" "config.py" "crawler.py" "database.py" "mcp_server.py" "requirements.txt"
      "templates/base.html" "templates/login.html" "templates/index.html"
      "templates/library.html" "templates/search.html" "templates/setup.html"
      "static/style.css"
    )
    for f in "${files[@]}"; do
      download_file "${REPO_RAW}/docserver-app/${f}" "${APP_SRC}/${f}" \
        || die "Download fehlgeschlagen: ${f}"
    done
    ok "App-Dateien von GitHub geladen (${#files[@]} Dateien)"
  fi
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
    --description "DocServer – lokale Context7-Alternative (installiert am $(date '+%Y-%m-%d %H:%M'))"
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
  header "Abhängigkeiten im Container installieren"
  pct exec "$CT_ID" -- bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq python3 python3-venv ca-certificates curl >/dev/null
  '
  ok "Systempakete installiert (python3, python3-venv)"

  header "App-Dateien in Container übertragen"
  pct exec "$CT_ID" -- mkdir -p "${APP_DIR}/app/templates" "${APP_DIR}/app/static" "${APP_DIR}/app/data/uploads"

  local f
  for f in app.py config.py crawler.py database.py mcp_server.py requirements.txt; do
    pct push "$CT_ID" "${APP_SRC}/${f}" "${APP_DIR}/app/${f}" >/dev/null
  done
  for f in "${APP_SRC}"/templates/*.html; do
    pct push "$CT_ID" "$f" "${APP_DIR}/app/templates/$(basename "$f")" >/dev/null
  done
  pct push "$CT_ID" "${APP_SRC}/static/style.css" "${APP_DIR}/app/static/style.css" >/dev/null
  ok "App-Dateien übertragen"

  header "Python-Umgebung einrichten"
  pct exec "$CT_ID" -- bash -c "
    set -euo pipefail
    python3 -m venv ${APP_DIR}/venv
    ${APP_DIR}/venv/bin/pip install --quiet --upgrade pip
    ${APP_DIR}/venv/bin/pip install --quiet -r ${APP_DIR}/app/requirements.txt
  "
  ok "virtuelle Umgebung + Abhängigkeiten installiert"
}

configure_service() {
  header "Dienst konfigurieren"
  local token
  if command -v openssl >/dev/null 2>&1; then
    token=$(openssl rand -hex 16)
  else
    token=$(head -c 16 /dev/urandom | sha256sum | cut -c1-32)
  fi

  local env_src="${TMP_DIR}/config.env"
  cat > "$env_src" <<EOF
PORT=${APP_PORT}
AUTH_TOKEN=${token}
EOF
  pct push "$CT_ID" "$env_src" "${APP_DIR}/config.env" >/dev/null

  local unit_src="${TMP_DIR}/docserver.service"
  if ${LOCAL_MODE} && [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docserver.service" ]]; then
    cp "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docserver.service" "$unit_src"
  else
    download_file "${REPO_RAW}/install/docserver.service" "$unit_src"
  fi
  pct push "$CT_ID" "$unit_src" "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null

  pct exec "$CT_ID" -- systemctl daemon-reload
  pct exec "$CT_ID" -- systemctl enable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    || pct exec "$CT_ID" -- systemctl restart "${SERVICE_NAME}.service"
  ok "systemd-Dienst aktiviert (Restart=always, After=network-online.target)"
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

  local tries=0
  until pct exec "$CT_ID" -- curl -sf "http://localhost:${APP_PORT}/api/health" >/dev/null 2>&1; do
    tries=$(( tries + 1 ))
    (( tries > 20 )) && {
      pct exec "$CT_ID" -- journalctl -u "${SERVICE_NAME}" -n 30 --no-pager || true
      die "Web-UI antwortet nicht auf Port ${APP_PORT}."
    }
    sleep 1.5
  done
  ok "Web-UI antwortet (HTTP 200 auf /api/health)"
}

get_ct_ip() {
  if [[ "${CT_IP}" == "dhcp" ]]; then
    pct exec "$CT_ID" -- hostname -I | awk '{print $1}'
  else
    echo "${CT_IP%%/*}"
  fi
}

print_summary() {
  local ct_ip token_html
  ct_ip=$(get_ct_ip)
  token_html=$(pct exec "$CT_ID" -- grep '^AUTH_TOKEN=' "${APP_DIR}/config.env" | cut -d= -f2)
  echo
  echo -e "${C_GREEN}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo -e "${C_GREEN}  📚  DocServer erfolgreich installiert!${C_RESET}"
  echo -e "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo -e "  Container      : CT ${CT_ID} (${CT_HOSTNAME}, ID ${CT_ID}, onboot)"
  echo -e "  Web-UI         : ${C_BOLD}http://${ct_ip}:${APP_PORT}${C_RESET}"
  echo -e "  MCP-Endpunkt   : ${C_BOLD}http://${ct_ip}:${APP_PORT}/mcp${C_RESET}"
  echo -e "  Auth-Token     : ${token_html}"
  echo -e "  REST-Suche     : http://${ct_ip}:${APP_PORT}/api/search?q=..."
  echo -e ""
  echo -e "  Client-Config  : http://${ct_ip}:${APP_PORT}/setup  (Copy-Paste-Snippets)"
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
  header "Update: DocServer"
  resolve_existing_ct
  if [[ "$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
    info "Container ist gestoppt – starte …"
    pct start "$CT_ID"
  fi
  download_app
  install_in_container
  pct exec "$CT_ID" -- systemctl restart "${SERVICE_NAME}"
  verify_installation
  print_summary
}

do_uninstall() {
  header "Deinstallation: DocServer"
  resolve_existing_ct
  warn "CT ${CT_ID} (${CT_HOSTNAME}) wird GESTOPPT und GELÖSCHT (inkl. aller Daten)!"
  read -r -p "Wirklich löschen? [y/N] " confirm
  [[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || die "Abgebrochen."
  pct stop "$CT_ID" 2>/dev/null || true
  pct destroy "$CT_ID" --purge
  ok "Container ${CT_ID} entfernt."
}

do_status() {
  header "Status: DocServer"
  resolve_existing_ct
  pct status "$CT_ID"
  pct exec "$CT_ID" -- systemctl is-active "${SERVICE_NAME}" || true
  local ct_ip
  ct_ip=$(get_ct_ip)
  if pct exec "$CT_ID" -- curl -sf "http://localhost:${APP_PORT}/api/health" >/dev/null 2>&1; then
    ok "Web-UI erreichbar: http://${ct_ip}:${APP_PORT}"
  else
    warn "Web-UI antwortet nicht."
  fi
}

# ───────────────────────────── Hauptablauf ─────────────────────────────────
main() {
  parse_args "$@"
  [[ $EUID -eq 0 ]] || die "Bitte als root ausführen (Proxmox-Host)."
  case "${MODE}" in
    install)
      echo -e "${C_BOLD}📚 DocServer – lokale Context7-Alternative (Proxmox-LXC-Installer)${C_RESET}"
      check_prerequisites
      create_container
      wait_for_network
      download_app
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
