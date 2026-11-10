#!/usr/bin/env bash
#
# Direct.sh - VPS Configuration for Direct Configs
# Version: 2.0.0

set -euo pipefail

readonly SCRIPT_NAME="Direct.sh"
readonly SCRIPT_VERSION="2.0.0"
readonly DEFAULT_TEMPLATE_REPO="Salarvand-Education/website-templates"
readonly DEFAULT_TEMPLATE_BRANCH="main"
readonly DEFAULT_WEB_ROOT="/var/www/html"
readonly DEFAULT_WORK_DIR="/root"
readonly LOG_FILE="/var/log/direct-setup.log"

TEMPLATE_REPO="${TEMPLATE_REPO:-$DEFAULT_TEMPLATE_REPO}"
TEMPLATE_BRANCH="${TEMPLATE_BRANCH:-$DEFAULT_TEMPLATE_BRANCH}"
WEB_ROOT="${WEB_ROOT:-$DEFAULT_WEB_ROOT}"
WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"
SKIP_PACKAGES="${SKIP_PACKAGES:-false}"
SKIP_TEMPLATE="${SKIP_TEMPLATE:-false}"
DRY_RUN="${DRY_RUN:-false}"

readonly REQUIRED_PACKAGES=("jq" "unzip" "nginx" "curl")

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly LOG_DEBUG=0
readonly LOG_INFO=1
readonly LOG_WARN=2
readonly LOG_ERROR=3
CURRENT_LOG_LEVEL=${LOG_LEVEL:-$LOG_INFO}

_log() {
    local level=$1 msg=$2 timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        $LOG_DEBUG) [[ $CURRENT_LOG_LEVEL -le $LOG_DEBUG ]] && echo -e "${BLUE}[DEBUG]${NC} $msg" ;;
        $LOG_INFO)  [[ $CURRENT_LOG_LEVEL -le $LOG_INFO ]]  && echo -e "${GREEN}[INFO]${NC} $msg" ;;
        $LOG_WARN)  [[ $CURRENT_LOG_LEVEL -le $LOG_WARN ]]  && echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        $LOG_ERROR) [[ $CURRENT_LOG_LEVEL -le $LOG_ERROR ]] && echo -e "${RED}[ERROR]${NC} $msg" ;;
    esac
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}
debug() { _log $LOG_DEBUG "$1"; }
info()  { _log $LOG_INFO "$1"; }
warn()  { _log $LOG_WARN "$1"; }
error() { _log $LOG_ERROR "$1"; }

run_cmd() {
    local cmd="$1" desc="${2:-$cmd}"
    [[ "$DRY_RUN" == "true" ]] && { info "[DRY-RUN] $desc"; return 0; }
    debug "Executing: $cmd"
    eval "$cmd" >> "$LOG_FILE" 2>&1 && { debug "Success: $desc"; return 0; } || {
        error "Failed: $desc (exit: $?)"; return 1; }
}

retry_cmd() {
    local max=3 delay=2 attempt=1 cmd="$1" desc="${2:-$cmd}"
    while [[ $attempt -le $max ]]; do
        run_cmd "$cmd" "$desc (attempt $attempt/$max)" && return 0
        [[ $attempt -lt $max ]] && { warn "Retrying in ${delay}s..."; sleep $delay; delay=$((delay*2)); }
        ((attempt++))
    done
    error "Failed after $max attempts: $desc"; return 1
}

check_root() { [[ $EUID -ne 0 ]] && { error "Run as root (sudo)"; exit 1; }; }
check_os() {
    source /etc/os-release 2>/dev/null || { error "Cannot detect OS"; exit 1; }
    [[ "$ID" != "ubuntu" && "$ID" != "debian" ]] && warn "OS '$ID' not officially supported"
    info "Detected OS: $PRETTY_NAME"
}

install_packages() {
    [[ "$SKIP_PACKAGES" == "true" ]] && { info "Skipping packages (SKIP_PACKAGES=true)"; return 0; }
    info "Installing: ${REQUIRED_PACKAGES[*]}"
    run_cmd "apt-get update -y" "Update package index" || return 1
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        command -v "$pkg" &>/dev/null && info "$pkg already installed" || {
            info "Installing $pkg..."; run_cmd "apt-get install -y $pkg" "Install $pkg" || return 1; }
    done
    info "All packages installed"
}

get_server_info() {
    info "Gathering server info..."
    local ip
    ip=$(hostname -I | awk '{print $1}') || { error "No server IP"; return 1; }
    [[ -z "$ip" ]] && { error "Empty server IP"; return 1; }
    info "Server IP: $ip"

    local country="" isp=""
    country=$(curl -sS --max-time 10 "http://ip-api.com/json/$ip?fields=country,isp" 2>/dev/null | jq -r '.country // empty' 2>/dev/null) && \
    isp=$(curl -sS --max-time 10 "http://ip-api.com/json/$ip?fields=country,isp" 2>/dev/null | jq -r '.isp // empty' 2>/dev/null)

    [[ -z "$country" || -z "$isp" ]] && {
        debug "Trying ipinfo.io fallback..."
        local fb
        fb=$(curl -sS --max-time 10 "https://ipinfo.io/$ip/json" 2>/dev/null) || true
        country="${country:-$(echo "$fb" | jq -r '.country // empty' 2>/dev/null)}"
        isp="${isp:-$(echo "$fb" | jq -r '.org // empty' 2>/dev/null)}"
    }
    [[ -z "$country" ]] && country="Unknown"
    [[ -z "$isp" ]] && isp="Unknown"
    info "Country: $country"; info "ISP: $isp"
    export SERVER_IP="$ip" SERVER_COUNTRY="$country" SERVER_ISP="$isp"
}

download_template() {
    [[ "$SKIP_TEMPLATE" == "true" ]] && { info "Skipping template (SKIP_TEMPLATE=true)"; return 0; }
    info "Downloading from $TEMPLATE_REPO@$TEMPLATE_BRANCH"
    local url="https://github.com/$TEMPLATE_REPO/archive/refs/heads/$TEMPLATE_BRANCH.zip"
    local zip="$WORK_DIR/template-$TEMPLATE_BRANCH.zip"
    local extract="$WORK_DIR/website-templates-$TEMPLATE_BRANCH"
    run_cmd "rm -rf '$extract' '$zip'" "Cleanup old files"
    retry_cmd "curl -fsSL -o '$zip' '$url'" "Download template" || return 1
    [[ -s "$zip" ]] || { error "Empty download"; return 1; }
    info "Extracting..."
    run_cmd "cd '$WORK_DIR' && unzip -q '$zip'" "Extract" || return 1
    local dir
    dir=$(find "$WORK_DIR" -maxdepth 1 -type d -name "website-templates-*" | head -1)
    [[ -z "$dir" ]] && { error "Template dir not found"; return 1; }
    export TEMPLATE_DIR="$dir"
    info "Extracted to: $TEMPLATE_DIR"
}

cleanup_template() {
    info "Cleaning template..."
    for p in assets .gitattributes README.md _config.yml "*.md" LICENSE*; do
        run_cmd "find '$TEMPLATE_DIR' -name '$p' -exec rm -rf {} +" "Remove $p" || true
    done
}

select_random_template() {
    info "Selecting random template..."
    local templates=()
    while IFS= read -r -d '' d; do [[ -d "$d" ]] && templates+=("$d"); done < <(find "$TEMPLATE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
    [[ ${#templates[@]} -eq 0 ]] && { error "No templates found"; return 1; }
    local sel="${templates[$((RANDOM % ${#templates[@]}))]}"
    export SELECTED_TEMPLATE="$sel" TEMPLATE_NAME="$(basename "$sel")"
    info "Selected: $TEMPLATE_NAME"
}

deploy_template() {
    info "Deploying to $WEB_ROOT..."
    [[ -d "$WEB_ROOT" ]] || run_cmd "mkdir -p '$WEB_ROOT'" "Create web root" || return 1
    [[ -n "$(ls -A "$WEB_ROOT" 2>/dev/null)" ]] && {
        run_cmd "mv '$WEB_ROOT' '/var/www/html.backup.$(date +%s)'" "Backup old content" || true
        run_cmd "mkdir -p '$WEB_ROOT'" "Recreate web root" || return 1; }
    run_cmd "cp -a '$SELECTED_TEMPLATE/.' '$WEB_ROOT/'" "Copy template" || return 1
    run_cmd "chown -R www-data:www-data '$WEB_ROOT'" "Fix ownership" || true
    run_cmd "find '$WEB_ROOT' -type f -exec chmod 644 {} +" "File perms" || true
    run_cmd "find '$WEB_ROOT' -type d -exec chmod 755 {} +" "Dir perms" || true
    info "Deployed: $TEMPLATE_NAME"
}

configure_nginx() {
    info "Configuring Nginx..."
    run_cmd "nginx -t" "Test config" || return 1
    run_cmd "systemctl enable nginx" "Enable service" || true
    run_cmd "systemctl restart nginx" "Restart Nginx" || return 1
    info "Nginx running"
}

main() {
    : > "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/direct-setup.log"; : > "$LOG_FILE"
    info "=== $SCRIPT_NAME v$SCRIPT_VERSION ==="
    info "Config: TEMPLATE_REPO=$TEMPLATE_REPO TEMPLATE_BRANCH=$TEMPLATE_BRANCH WEB_ROOT=$WEB_ROOT"
    [[ "$DRY_RUN" == "true" ]] && warn "DRY RUN MODE"
    check_root; check_os
    install_packages || exit 1
    get_server_info || exit 1
    [[ "$SKIP_TEMPLATE" != "true" ]] && {
        download_template || exit 1
        cleanup_template || exit 1
        select_random_template || exit 1
        deploy_template || exit 1
    }
    configure_nginx || exit 1
    info "=== Done ==="
    info "IP: $SERVER_IP | Country: $SERVER_COUNTRY | ISP: $SERVER_ISP"
    [[ "$SKIP_TEMPLATE" != "true" ]] && info "Template: $TEMPLATE_NAME"
    info "Web root: $WEB_ROOT | Nginx: $(systemctl is-active nginx 2>/dev/null || echo unknown)"
}

show_help() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION - VPS Config for Direct Configs
Usage: bash <(curl -s https://raw.githubusercontent.com/Salarvand-Education/Direct/main/Direct.sh)
Env vars:
  TEMPLATE_REPO      Template repo (default: $DEFAULT_TEMPLATE_REPO)
  TEMPLATE_BRANCH    Branch (default: $DEFAULT_TEMPLATE_BRANCH)
  WEB_ROOT           Web root (default: $DEFAULT_WEB_ROOT)
  WORK_DIR           Work dir (default: $DEFAULT_WORK_DIR)
  SKIP_PACKAGES      Skip apt install (default: false)
  SKIP_TEMPLATE      Skip template deploy (default: false)
  DRY_RUN            No changes (default: false)
  LOG_LEVEL          0=DEBUG 1=INFO 2=WARN 3=ERROR (default: 1)
Examples:
  TEMPLATE_REPO="myorg/repo" bash <(curl -s ...)
  SKIP_TEMPLATE=true bash <(curl -s ...)
  DRY_RUN=true bash <(curl -s ...)
EOF
}
case "${1:-}" in -h|--help) show_help; exit 0;; -v|--version) echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0;; esac
main "$@"