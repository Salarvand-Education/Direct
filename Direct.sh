#!/usr/bin/env bash
#
# Direct.sh - VPS Configuration for Direct Configs
# Version: 2.0.0

set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="Direct.sh"
readonly SCRIPT_VERSION="2.0.0"
readonly DEFAULT_TEMPLATE_REPO="Salarvand-Education/website-templates"
readonly DEFAULT_TEMPLATE_BRANCH="main"
readonly DEFAULT_WEB_ROOT="/var/www/html"
readonly DEFAULT_WORK_DIR="/root"
readonly LOG_FILE="/var/log/direct-setup.log"

# Override via env
TEMPLATE_REPO="${TEMPLATE_REPO:-$DEFAULT_TEMPLATE_REPO}"
TEMPLATE_BRANCH="${TEMPLATE_BRANCH:-$DEFAULT_TEMPLATE_BRANCH}"
WEB_ROOT="${WEB_ROOT:-$DEFAULT_WEB_ROOT}"
WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"
SKIP_PACKAGES="${SKIP_PACKAGES:-false}"
SKIP_TEMPLATE="${SKIP_TEMPLATE:-false}"
DRY_RUN="${DRY_RUN:-false}"

readonly REQUIRED_PACKAGES=("jq" "unzip" "nginx" "curl")

# ─── Colors & Logging ──────────────────────────────────────────────────────
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' NC='\033[0m'
readonly LOG_DEBUG=0 LOG_INFO=1 LOG_WARN=2 LOG_ERROR=3
CURRENT_LOG_LEVEL=${LOG_LEVEL:-$LOG_INFO}

_log() {
    local level=$1 msg=$2 ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        $LOG_DEBUG) [[ $CURRENT_LOG_LEVEL -le $LOG_DEBUG ]] && echo -e "${BLUE}[DEBUG]${NC} $msg" ;;
        $LOG_INFO)  [[ $CURRENT_LOG_LEVEL -le $LOG_INFO ]]  && echo -e "${GREEN}[INFO]${NC} $msg" ;;
        $LOG_WARN)  [[ $CURRENT_LOG_LEVEL -le $LOG_WARN ]]  && echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        $LOG_ERROR) [[ $CURRENT_LOG_LEVEL -le $LOG_ERROR ]] && echo -e "${RED}[ERROR]${NC} $msg" ;;
    esac
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}
debug() { _log $LOG_DEBUG "$1"; }
info()  { _log $LOG_INFO "$1"; }
warn()  { _log $LOG_WARN "$1"; }
error() { _log $LOG_ERROR "$1"; }

# ─── Helpers ───────────────────────────────────────────────────────────────
run_cmd() {
    local cmd=$1 desc=${2:-$1}
    [[ $DRY_RUN == true ]] && { info "[DRY-RUN] $desc"; return 0; }
    debug "Running: $cmd"
    eval "$cmd" >> "$LOG_FILE" 2>&1 && { debug "OK: $desc"; return 0; } || {
        error "Failed: $desc (code $?)"; return 1; }
}

retry_cmd() {
    local max=3 delay=2 i=1 cmd=$1 desc=${2:-$1}
    while (( i <= max )); do
        run_cmd "$cmd" "$desc (try $i/$max)" && return 0
        (( i < max )) && { warn "Retry in ${delay}s..."; sleep $delay; delay=$((delay*2)); }
        ((i++))
    done
    error "Gave up after $max tries: $desc"; return 1
}

check_root() { (( EUID != 0 )) && { error "Need root (sudo)"; exit 1; }; }
check_os() {
    source /etc/os-release 2>/dev/null || { error "Unknown OS"; exit 1; }
    [[ $ID != ubuntu && $ID != debian ]] && warn "Untested on $ID"
    info "OS: $PRETTY_NAME"
}

# ─── Package Install ───────────────────────────────────────────────────────
install_packages() {
    [[ $SKIP_PACKAGES == true ]] && { info "Skipping apt (SKIP_PACKAGES)"; return 0; }
    info "Installing: ${REQUIRED_PACKAGES[*]}"
    run_cmd "apt-get update -y" "apt update" || return 1
    for p in "${REQUIRED_PACKAGES[@]}"; do
        command -v "$p" &>/dev/null && info "$p OK" || {
            info "Installing $p..."; run_cmd "apt-get install -y $p" "install $p" || return 1; }
    done
    info "Packages done"
}

# ─── Server Info ───────────────────────────────────────────────────────────
get_server_info() {
    info "Getting server info..."
    local ip
    ip=$(hostname -I | awk '{print $1}') || { error "No IP found"; return 1; }
    [[ -z $ip ]] && { error "Empty IP"; return 1; }
    info "IP: $ip"

    local country="" isp=""
    country=$(curl -sS --max-time 10 "http://ip-api.com/json/$ip?fields=country,isp" 2>/dev/null | jq -r '.country // empty' 2>/dev/null) && \
    isp=$(curl -sS --max-time 10 "http://ip-api.com/json/$ip?fields=country,isp" 2>/dev/null | jq -r '.isp // empty' 2>/dev/null)

    if [[ -z $country || -z $isp ]]; then
        debug "ip-api failed, trying ipinfo.io..."
        local fb
        fb=$(curl -sS --max-time 10 "https://ipinfo.io/$ip/json" 2>/dev/null) || true
        country=${country:-$(echo "$fb" | jq -r '.country // empty' 2>/dev/null)}
        isp=${isp:-$(echo "$fb" | jq -r '.org // empty' 2>/dev/null)}
    fi
    country=${country:-Unknown}
    isp=${isp:-Unknown}
    info "Country: $country | ISP: $isp"
    export SERVER_IP=$ip SERVER_COUNTRY=$country SERVER_ISP=$isp
}

# ─── Template Handling ─────────────────────────────────────────────────────
download_template() {
    [[ $SKIP_TEMPLATE == true ]] && { info "Skipping template (SKIP_TEMPLATE)"; return 0; }
    info "Downloading $TEMPLATE_REPO@$TEMPLATE_BRANCH"
    local url="https://github.com/$TEMPLATE_REPO/archive/refs/heads/$TEMPLATE_BRANCH.zip"
    local zip="$WORK_DIR/template-$TEMPLATE_BRANCH.zip"
    run_cmd "rm -rf '$WORK_DIR/website-templates-*' '$zip'" "Cleanup"
    retry_cmd "curl -fsSL -o '$zip' '$url'" "Download" || return 1
    [[ -s $zip ]] || { error "Empty zip"; return 1; }
    run_cmd "cd '$WORK_DIR' && unzip -q '$zip'" "Unzip" || return 1
    local dir
    dir=$(find "$WORK_DIR" -maxdepth 1 -type d -name 'website-templates-*' | head -1)
    [[ -z $dir ]] && { error "Template dir missing"; return 1; }
    export TEMPLATE_DIR=$dir
    info "Template at: $TEMPLATE_DIR"
}

cleanup_template() {
    info "Removing junk from template..."
    for p in assets .gitattributes README.md _config.yml "*.md" LICENSE*; do
        run_cmd "find '$TEMPLATE_DIR' -name '$p' -exec rm -rf {} +" "rm $p" || true
    done
}

select_random_template() {
    info "Picking random template..."
    local arr=()
    while IFS= read -r -d '' d; do [[ -d $d ]] && arr+=("$d"); done < <(find "$TEMPLATE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
    (( ${#arr[@]} == 0 )) && { error "No templates"; return 1; }
    local pick=${arr[$((RANDOM % ${#arr[@]}))]}
    export SELECTED_TEMPLATE=$pick TEMPLATE_NAME=$(basename "$pick")
    info "Using: $TEMPLATE_NAME"
}

deploy_template() {
    info "Deploying to $WEB_ROOT..."
    [[ -d $WEB_ROOT ]] || run_cmd "mkdir -p '$WEB_ROOT'" "mkdir webroot" || return 1
    [[ -n $(ls -A "$WEB_ROOT" 2>/dev/null) ]] && {
        run_cmd "mv '$WEB_ROOT' '/var/www/html.backup.$(date +%s)'" "backup old" || true
        run_cmd "mkdir -p '$WEB_ROOT'" "recreate webroot" || return 1; }
    run_cmd "cp -a '$SELECTED_TEMPLATE/.' '$WEB_ROOT/'" "copy files" || return 1
    run_cmd "chown -R www-data:www-data '$WEB_ROOT'" "fix owner" || true
    run_cmd "find '$WEB_ROOT' -type f -exec chmod 644 {} +" "file perms" || true
    run_cmd "find '$WEB_ROOT' -type d -exec chmod 755 {} +" "dir perms" || true
    info "Deployed: $TEMPLATE_NAME"
}

# ─── Nginx ─────────────────────────────────────────────────────────────────
configure_nginx() {
    info "Setting up Nginx..."
    run_cmd "nginx -t" "test config" || return 1
    run_cmd "systemctl enable nginx" "enable" || true
    run_cmd "systemctl restart nginx" "restart" || return 1
    info "Nginx up"
}

# ─── Main ──────────────────────────────────────────────────────────────────
main() {
    : > "$LOG_FILE" 2>/dev/null || LOG_FILE=/tmp/direct-setup.log
    : > "$LOG_FILE"
    info "=== $SCRIPT_NAME v$SCRIPT_VERSION ==="
    info "Repo: $TEMPLATE_REPO  Branch: $TEMPLATE_BRANCH  Root: $WEB_ROOT"
    [[ $DRY_RUN == true ]] && warn "DRY RUN - no changes"
    check_root; check_os
    install_packages || exit 1
    get_server_info || exit 1
    [[ $SKIP_TEMPLATE != true ]] && {
        download_template || exit 1
        cleanup_template || exit 1
        select_random_template || exit 1
        deploy_template || exit 1
    }
    configure_nginx || exit 1
    info "=== Done ==="
    info "IP: $SERVER_IP  Country: $SERVER_COUNTRY  ISP: $SERVER_ISP"
    [[ $SKIP_TEMPLATE != true ]] && info "Template: $TEMPLATE_NAME"
    info "Web: $WEB_ROOT  Nginx: $(systemctl is-active nginx 2>/dev/null || echo unknown)"
}

# ─── Help ──────────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION - VPS setup for direct configs
Usage: bash <(curl -s https://raw.githubusercontent.com/Salarvand-Education/Direct/main/Direct.sh)

Env vars:
  TEMPLATE_REPO      Repo with templates (default: $DEFAULT_TEMPLATE_REPO)
  TEMPLATE_BRANCH    Branch to use (default: $DEFAULT_TEMPLATE_BRANCH)
  WEB_ROOT           Web root dir (default: $DEFAULT_WEB_ROOT)
  WORK_DIR           Work dir (default: $DEFAULT_WORK_DIR)
  SKIP_PACKAGES      Skip apt install (default: false)
  SKIP_TEMPLATE      Skip template deploy (default: false)
  DRY_RUN            Test run, no changes (default: false)
  LOG_LEVEL          0=DEBUG 1=INFO 2=WARN 3=ERROR (default: 1)

Examples:
  TEMPLATE_REPO="me/myrepo" bash <(curl -s ...)
  SKIP_TEMPLATE=true bash <(curl -s ...)
  DRY_RUN=true bash <(curl -s ...)
EOF
}
case ${1:-} in -h|--help) show_help; exit 0;; -v|--version) echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0;; esac
main "$@"