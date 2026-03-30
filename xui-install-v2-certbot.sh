#!/usr/bin/env bash
# =============================================================================
# xui-install.sh — Install & manage x-ui WITHOUT systemctl or Docker
#
# Usage:
#   bash xui-install.sh                       # install (or upgrade) x-ui
#   bash xui-install.sh start                 # start the panel in background
#   bash xui-install.sh stop                  # stop the panel
#   bash xui-install.sh restart               # restart the panel
#   bash xui-install.sh status                # show running status
#   bash xui-install.sh log                   # tail the log file
#   bash xui-install.sh settings              # show current panel settings
#   bash xui-install.sh uri                   # show panel access URL(s)
#   bash xui-install.sh setting -port 8080 -username foo -password bar
#                                            # change panel settings (pass-through to x-ui binary)
#   bash xui-install.sh certbot-install       # install certbot + renewal support
#   bash xui-install.sh certbot-issue example.com admin@example.com
#                                            # issue cert and attach it to x-ui panel
#   bash xui-install.sh certbot-set example.com
#                                            # attach an existing certbot cert to x-ui panel
#   bash xui-install.sh certbot-renew         # renew certs and reload x-ui if needed
#   bash xui-install.sh uninstall             # remove everything
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

info()  { echo -e "${GREEN}[INFO]${PLAIN}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN}  $*"; }
error() { echo -e "${RED}[ERR]${PLAIN}   $*"; }
die()   { error "$*"; exit 1; }

# ── Paths (all configurable via env) ─────────────────────────────────────────
INSTALL_DIR="${XUI_INSTALL_DIR:-/usr/local/x-ui}"
DB_DIR="${XUI_DB_FOLDER:-/etc/x-ui}"
LOG_FILE="${XUI_LOG_FILE:-/var/log/x-ui.log}"
PID_FILE="${XUI_PID_FILE:-/var/run/x-ui.pid}"
CLI_LINK="${XUI_CLI_LINK:-/usr/local/bin/x-ui}"
CERTBOT_DEPLOY_HOOK="${XUI_CERTBOT_DEPLOY_HOOK:-/usr/local/bin/x-ui-certbot-deploy-hook.sh}"

# ── Architecture detection ────────────────────────────────────────────────────
detect_arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64)       echo "amd64" ;;
        i*86|x86)               echo "386"   ;;
        aarch64|arm64|armv8*)   echo "arm64" ;;
        armv7*|armv7)           echo "armv7" ;;
        armv6*|armv6)           echo "armv6" ;;
        armv5*|armv5)           echo "armv5" ;;
        s390x)                  echo "s390x" ;;
        *) die "Unsupported CPU architecture: $(uname -m)" ;;
    esac
}

ARCH="$(detect_arch)"

# ── Random string helper ──────────────────────────────────────────────────────
gen_random() {
    local len="${1:-10}"
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$len" | head -n 1
}

# ── Root check ────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (try: sudo bash $0 $*)"
}

# ── Dependency installer (best-effort, skips missing pkg managers) ───────────
install_deps() {
    local pkgs="wget curl tar"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -q $pkgs || true
    elif command -v yum &>/dev/null; then
        yum install -y -q $pkgs || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q $pkgs || true
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm $pkgs || true
    elif command -v zypper &>/dev/null; then
        zypper -q install -y $pkgs || true
    else
        warn "Cannot detect package manager — assuming wget/curl/tar are already present."
    fi
}

install_certbot_deps() {
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -q certbot cron || true
    elif command -v yum &>/dev/null; then
        yum install -y -q certbot cronie || yum install -y -q certbot cron || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q certbot cronie || dnf install -y -q certbot cron || true
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm certbot cronie || true
    elif command -v zypper &>/dev/null; then
        zypper -q install -y certbot cron || true
    else
        warn "Cannot detect package manager — install certbot manually if missing."
    fi
}

# ── PID file helpers ──────────────────────────────────────────────────────────
xui_pid() {
    [[ -f "$PID_FILE" ]] && cat "$PID_FILE" || echo ""
}

xui_running() {
    local pid; pid="$(xui_pid)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ── Start x-ui in the background ─────────────────────────────────────────────
cmd_start() {
    if xui_running; then
        info "x-ui is already running (PID $(xui_pid))."
        return 0
    fi

    [[ -x "$INSTALL_DIR/x-ui" ]] || die "x-ui binary not found at $INSTALL_DIR/x-ui — run install first."

    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"

    export XUI_DB_FOLDER="$DB_DIR"
    export XUI_BIN_FOLDER="$INSTALL_DIR/bin"
    export XRAY_VMESS_AEAD_FORCED=false

    nohup "$INSTALL_DIR/x-ui" run >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        info "x-ui started — PID $pid"
        info "Log: $LOG_FILE"
    else
        rm -f "$PID_FILE"
        die "x-ui exited immediately. Check the log: $LOG_FILE"
    fi
}

# ── Stop x-ui ─────────────────────────────────────────────────────────────────
cmd_stop() {
    if ! xui_running; then
        info "x-ui is not running."
        return 0
    fi
    local pid; pid="$(xui_pid)"
    info "Stopping x-ui (PID $pid)…"
    kill -TERM "$pid" 2>/dev/null || true
    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 10 ]]; do
        sleep 0.5; ((i++))
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    info "x-ui stopped."
}

# ── Restart ───────────────────────────────────────────────────────────────────
cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

# ── Status ────────────────────────────────────────────────────────────────────
cmd_status() {
    if xui_running; then
        info "x-ui is RUNNING — PID $(xui_pid)"
    else
        warn "x-ui is NOT running."
    fi

    if pgrep -f "xray-linux" &>/dev/null; then
        info "xray-core is RUNNING"
    else
        warn "xray-core is NOT running"
    fi
}

# ── Show settings ─────────────────────────────────────────────────────────────
cmd_settings() {
    XUI_DB_FOLDER="$DB_DIR" XUI_BIN_FOLDER="$INSTALL_DIR/bin" \
        "$INSTALL_DIR/x-ui" setting -show true 2>/dev/null | grep -v '^(0x'
}

# ── Show URI ──────────────────────────────────────────────────────────────────
cmd_uri() {
    XUI_DB_FOLDER="$DB_DIR" XUI_BIN_FOLDER="$INSTALL_DIR/bin" \
        "$INSTALL_DIR/x-ui" uri
}

# ── Tail log ──────────────────────────────────────────────────────────────────
cmd_log() {
    [[ -f "$LOG_FILE" ]] || die "Log file not found: $LOG_FILE"
    tail -f "$LOG_FILE"
}

# ── Pass-through 'setting/settings' subcommand (write flags) ─────────────────
cmd_setting_passthrough() {
    XUI_DB_FOLDER="$DB_DIR" XUI_BIN_FOLDER="$INSTALL_DIR/bin" \
        "$INSTALL_DIR/x-ui" setting "$@" 2>/dev/null | grep -v '^(0x'
    info "Settings updated. Restart x-ui for changes to take effect: x-ui restart"
    echo ""
    cmd_settings
}

# ── Certbot helpers ───────────────────────────────────────────────────────────
certbot_live_dir() {
    local domain="$1"
    echo "/etc/letsencrypt/live/${domain}"
}

require_xui_binary() {
    [[ -x "$INSTALL_DIR/x-ui" ]] || die "x-ui binary not found at $INSTALL_DIR/x-ui — run install first."
}

ensure_certbot() {
    command -v certbot &>/dev/null || die "certbot is not installed. Run: $CLI_LINK certbot-install"
}

write_certbot_deploy_hook() {
    cat > "$CERTBOT_DEPLOY_HOOK" <<EOF_HOOK
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="${INSTALL_DIR}"
DB_DIR="${DB_DIR}"
PID_FILE="${PID_FILE}"
LOG_FILE="${LOG_FILE}"

if [[ ! -x "$INSTALL_DIR/x-ui" ]]; then
    exit 0
fi

if [[ -z "${RENEWED_LINEAGE:-}" ]]; then
    exit 0
fi

web_cert="$RENEWED_LINEAGE/fullchain.pem"
web_key="$RENEWED_LINEAGE/privkey.pem"

if [[ ! -f "$web_cert" || ! -f "$web_key" ]]; then
    exit 1
fi

XUI_DB_FOLDER="$DB_DIR" XUI_BIN_FOLDER="$INSTALL_DIR/bin" \
    "$INSTALL_DIR/x-ui" cert -webCert "$web_cert" -webCertKey "$web_key"

if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        nohup "$INSTALL_DIR/x-ui" run >> "$LOG_FILE" 2>&1 &
        echo "$!" > "$PID_FILE"
    fi
fi
EOF_HOOK
    chmod 700 "$CERTBOT_DEPLOY_HOOK"
}

cmd_certbot_install() {
    require_root
    info "Installing certbot and renewal prerequisites…"
    install_certbot_deps
    command -v certbot &>/dev/null || die "certbot install did not complete successfully."
    write_certbot_deploy_hook
    info "certbot is installed."
    info "Deploy hook installed at: $CERTBOT_DEPLOY_HOOK"
    warn "Automatic renewal still depends on a working cron/timer setup on your server."
}

cmd_certbot_set() {
    require_root
    require_xui_binary
    ensure_certbot

    local domain="${1:-}"
    [[ -n "$domain" ]] || die "Usage: $CLI_LINK certbot-set <domain>"

    local live_dir cert_file key_file
    live_dir="$(certbot_live_dir "$domain")"
    cert_file="$live_dir/fullchain.pem"
    key_file="$live_dir/privkey.pem"

    [[ -f "$cert_file" ]] || die "Certificate file not found: $cert_file"
    [[ -f "$key_file" ]] || die "Private key file not found: $key_file"

    XUI_DB_FOLDER="$DB_DIR" XUI_BIN_FOLDER="$INSTALL_DIR/bin" \
        "$INSTALL_DIR/x-ui" cert -webCert "$cert_file" -webCertKey "$key_file"

    info "x-ui panel certificate updated for domain: $domain"
    info "Certificate: $cert_file"
    info "Private key: $key_file"

    if xui_running; then
        cmd_restart
    else
        warn "x-ui is not running. Start it with: $CLI_LINK start"
    fi
}

cmd_certbot_issue() {
    require_root
    require_xui_binary
    ensure_certbot

    local domain="${1:-}"
    local email="${2:-}"
    [[ -n "$domain" && -n "$email" ]] || die "Usage: $CLI_LINK certbot-issue <domain> <email>"

    write_certbot_deploy_hook

    warn "certbot standalone needs TCP port 80 reachable from the internet for ${domain}."
    if ss -lnt '( sport = :80 )' 2>/dev/null | grep -q ':80'; then
        warn "Port 80 appears to be in use. certbot standalone may fail until that listener is stopped."
    fi

    certbot certonly \
        --standalone \
        --preferred-challenges http \
        --non-interactive \
        --agree-tos \
        --email "$email" \
        --deploy-hook "$CERTBOT_DEPLOY_HOOK" \
        -d "$domain"

    info "Certificate issued successfully for: $domain"
    cmd_certbot_set "$domain"
}

cmd_certbot_renew() {
    require_root
    ensure_certbot
    write_certbot_deploy_hook
    certbot renew --deploy-hook "$CERTBOT_DEPLOY_HOOK"
    info "certbot renew completed."
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
cmd_uninstall() {
    cmd_stop 2>/dev/null || true
    info "Removing $INSTALL_DIR …"
    rm -rf "$INSTALL_DIR"
    info "Removing $DB_DIR …"
    rm -rf "$DB_DIR"
    rm -f "$LOG_FILE" "$PID_FILE" "$CLI_LINK"
    info "x-ui uninstalled."
}

# ── Post-install first-run configuration ─────────────────────────────────────
config_after_install() {
    local existing_user existing_pass existing_basepath

    existing_user=$(XUI_DB_FOLDER="$DB_DIR" XUI_BIN_FOLDER="$INSTALL_DIR/bin" \
        "$INSTALL_DIR/x-ui" setting -show true 2>/dev/null \
        | grep -Eo 'username: .+' | awk '{print $2}')

    existing_pass=$(XUI_DB_FOLDER="$DB_DIR" XUI_BIN_FOLDER="$INSTALL_DIR/bin" \
        "$INSTALL_DIR/x-ui" setting -show true 2>/dev/null \
        | grep -Eo 'password: .+' | awk '{print $2}')

    existing_basepath=$(XUI_DB_FOLDER="$DB_DIR" XUI_BIN_FOLDER="$INSTALL_DIR/bin" \
        "$INSTALL_DIR/x-ui" setting -show true 2>/dev/null \
        | grep -Eo 'webBasePath: .+' | awk '{print $2}')

    local need_creds=false need_basepath=false

    if [[ "$existing_user" == "admin" && "$existing_pass" == "admin" ]]; then
        need_creds=true
    fi

    if [[ ${#existing_basepath} -lt 4 ]]; then
        need_basepath=true
    fi

    if $need_creds || $need_basepath; then
        info "Securing the panel with randomised credentials…"

        local new_user new_pass new_port new_basepath
        new_user="$(gen_random 10)"
        new_pass="$(gen_random 10)"
        new_basepath="$(gen_random 15)"
        new_port="$(shuf -i 10000-62000 -n 1 2>/dev/null || echo 54321)"

        local args="-webBasePath $new_basepath"
        $need_creds    && args="$args -username $new_user -password $new_pass -port $new_port"

        # shellcheck disable=SC2086
        XUI_DB_FOLDER="$DB_DIR" XUI_BIN_FOLDER="$INSTALL_DIR/bin" \
            "$INSTALL_DIR/x-ui" setting $args

        echo ""
        echo -e "╔══════════════════════════════════════════╗"
        echo -e "║         x-ui  Panel Credentials          ║"
        echo -e "╠══════════════════════════════════════════╣"
        if $need_creds; then
        echo -e "║  Username   : ${GREEN}${new_user}${PLAIN}"
        echo -e "║  Password   : ${GREEN}${new_pass}${PLAIN}"
        echo -e "║  Port       : ${GREEN}${new_port}${PLAIN}"
        fi
        echo -e "║  BasePath   : ${GREEN}/${new_basepath}${PLAIN}"
        echo -e "╚══════════════════════════════════════════╝"
        echo -e "${YELLOW}Save these — run '$CLI_LINK settings' later to see them again.${PLAIN}"
        echo ""
    fi

    XUI_DB_FOLDER="$DB_DIR" XUI_BIN_FOLDER="$INSTALL_DIR/bin" \
        "$INSTALL_DIR/x-ui" migrate || true
}

# ── Main install ──────────────────────────────────────────────────────────────
cmd_install() {
    require_root

    info "Installing dependencies…"
    install_deps

    info "Fetching latest x-ui release…"
    local version
    version="$(curl -fsSL "https://api.github.com/repos/alireza0/x-ui/releases/latest" \
        | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')"
    [[ -n "$version" ]] || die "Could not determine latest x-ui version (GitHub API may be rate-limited)."
    info "Latest version: $version"

    local tarball="x-ui-linux-${ARCH}.tar.gz"
    local url="https://github.com/alireza0/x-ui/releases/download/${version}/${tarball}"

    local tmp; tmp="$(mktemp -d)"
    info "Downloading $url …"
    curl -fsSL -o "$tmp/$tarball" "$url" \
        || die "Download failed. Check connectivity / GitHub access."

    local have_db=false
    if [[ -f "$DB_DIR/x-ui.db" ]]; then
        have_db=true
        cp "$DB_DIR/x-ui.db" "$tmp/x-ui.db.bak"
        info "Existing database backed up."
    fi

    if xui_running; then
        info "Stopping running instance…"
        cmd_stop
    fi

    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    info "Extracting…"
    tar -xzf "$tmp/$tarball" -C "$tmp"
    cp -r "$tmp/x-ui/." "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/x-ui"

    if [[ "$ARCH" == "armv7" ]]; then
        mv -f "$INSTALL_DIR/bin/xray-linux-armv7" \
               "$INSTALL_DIR/bin/xray-linux-arm" 2>/dev/null || true
    fi
    chmod +x "$INSTALL_DIR/bin/xray-linux-"* 2>/dev/null || true

    mkdir -p "$DB_DIR"
    if $have_db; then
        cp "$tmp/x-ui.db.bak" "$DB_DIR/x-ui.db"
        info "Previous database restored."
    fi

    cp -f "$0" "$CLI_LINK"
    chmod +x "$CLI_LINK"

    config_after_install
    write_certbot_deploy_hook

    rm -rf "$tmp"

    info "x-ui ${version} installed to $INSTALL_DIR"

    cmd_start

    echo ""
    info "Panel access URL(s):"
    cmd_uri || true
    echo ""
    echo -e "═══════════════════════════════════════════════"
    echo -e " ${GREEN}x-ui CLI usage (from anywhere):${PLAIN}"
    echo -e "   x-ui              — this help menu"
    echo -e "   x-ui start        — start panel"
    echo -e "   x-ui stop         — stop panel"
    echo -e "   x-ui restart      — restart panel"
    echo -e "   x-ui status       — running status"
    echo -e "   x-ui settings     — show credentials & port"
    echo -e "   x-ui uri          — show panel URL"
    echo -e "   x-ui log          — tail live log"
    echo -e "   x-ui certbot-install"
    echo -e "   x-ui certbot-issue example.com admin@example.com"
    echo -e "   x-ui certbot-set example.com"
    echo -e "   x-ui certbot-renew"
    echo -e "   x-ui setting -port 9090 -username u -password p"
    echo -e "   x-ui uninstall    — remove everything"
    echo -e "═══════════════════════════════════════════════"
}

# ── Help / menu ───────────────────────────────────────────────────────────────
cmd_help() {
    echo -e "${GREEN}x-ui — systemctl-free control script${PLAIN}"
    echo ""
    echo "COMMANDS:"
    echo "  (no args)                    Run install wizard"
    echo "  start                        Start x-ui panel in background"
    echo "  stop                         Stop x-ui panel"
    echo "  restart                      Restart x-ui panel"
    echo "  status                       Show running status"
    echo "  settings                     Show panel credentials & port"
    echo "  uri                          Show panel access URL(s)"
    echo "  log                          Tail the live log"
    echo "  setting [flags]              Change panel settings (passed to x-ui binary)"
    echo "                               flags: -port N  -username S  -password S  -webBasePath S"
    echo "                                      -reset   -show"
    echo "  certbot-install              Install certbot + renewal prerequisites"
    echo "  certbot-issue <domain> <email>"
    echo "                               Issue certbot certificate and attach it to x-ui panel"
    echo "  certbot-set <domain>         Use existing certbot certificate for x-ui panel"
    echo "  certbot-renew                Renew certificates and reload x-ui if needed"
    echo "  uninstall                    Remove x-ui, database, and log"
    echo "  help                         This message"
    echo ""
    echo "ENVIRONMENT (all optional):"
    echo "  XUI_INSTALL_DIR              where to install x-ui        (default: /usr/local/x-ui)"
    echo "  XUI_DB_FOLDER                database directory           (default: /etc/x-ui)"
    echo "  XUI_LOG_FILE                 log file path                (default: /var/log/x-ui.log)"
    echo "  XUI_PID_FILE                 PID file path                (default: /var/run/x-ui.pid)"
    echo "  XUI_CLI_LINK                 command link path            (default: /usr/local/bin/x-ui)"
    echo "  XUI_CERTBOT_DEPLOY_HOOK      certbot deploy hook path     (default: /usr/local/bin/x-ui-certbot-deploy-hook.sh)"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-install}"

    case "$cmd" in
        install)             require_root; cmd_install ;;
        start)               require_root; cmd_start ;;
        stop)                require_root; cmd_stop ;;
        restart)             require_root; cmd_restart ;;
        status)              cmd_status ;;
        settings|setting)
            shift
            if [[ $# -eq 0 ]]; then
                cmd_settings
            else
                require_root
                cmd_setting_passthrough "$@"
            fi
            ;;
        uri)                 cmd_uri ;;
        log)                 cmd_log ;;
        certbot-install)     cmd_certbot_install ;;
        certbot-issue)       shift; cmd_certbot_issue "$@" ;;
        certbot-set)         shift; cmd_certbot_set "$@" ;;
        certbot-renew)       cmd_certbot_renew ;;
        uninstall)           require_root; cmd_uninstall ;;
        help|--help|-h)      cmd_help ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
