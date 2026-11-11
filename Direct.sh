#!/usr/bin/env bash
#
# Direct.sh - VPS Configuration for Direct Configs
# Version: 2.0.0

set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="Direct.sh"
readonly SCRIPT_VERSION="2.1.0"
readonly DEFAULT_TEMPLATE_REPO="Salarvand-Education/website-templates"
readonly DEFAULT_TEMPLATE_BRANCH="main"
readonly DEFAULT_WEB_ROOT="/var/www/html"
readonly DEFAULT_WORK_DIR="/root"
readonly DEFAULT_LOG_FILE="/var/log/direct-setup.log"

# Override via env
TEMPLATE_REPO="${TEMPLATE_REPO:-$DEFAULT_TEMPLATE_REPO}"
TEMPLATE_BRANCH="${TEMPLATE_BRANCH:-$DEFAULT_TEMPLATE_BRANCH}"
WEB_ROOT="${WEB_ROOT:-$DEFAULT_WEB_ROOT}"
WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
SKIP_PACKAGES="${SKIP_PACKAGES:-false}"
SKIP_TEMPLATE="${SKIP_TEMPLATE:-false}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_ROOT_CHECK="${SKIP_ROOT_CHECK:-false}"
SKIP_OS_CHECK="${SKIP_OS_CHECK:-false}"
SKIP_SERVER_INFO="${SKIP_SERVER_INFO:-false}"
LOG_JSON="${LOG_JSON:-false}"

# Package names by OS family
declare -A REQUIRED_PACKAGES=(
    [debian]="jq unzip nginx curl"
    [ubuntu]="jq unzip nginx curl"
    [rhel]="jq unzip nginx curl"
    [fedora]="jq unzip nginx curl"
    [alpine]="jq unzip nginx curl"
)

# ─── Colors & Logging ──────────────────────────────────────────────────────
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' NC='\033[0m'
readonly LOG_DEBUG=0 LOG_INFO=1 LOG_WARN=2 LOG_ERROR=3
CURRENT_LOG_LEVEL=${LOG_LEVEL:-$LOG_INFO}

_log_json() {
    local level=$1 msg=$2 ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{"timestamp":"%s","level":%d,"message":"%s"}\n' "$ts" "$level" "$msg"
}

_log() {
    local level=$1 msg=$2 ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ $LOG_JSON == true ]]; then
        _log_json "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
    case $level in
        $LOG_DEBUG) [[ $CURRENT_LOG_LEVEL -le $LOG_DEBUG ]] && echo -e "${BLUE}[DEBUG]${NC} $msg" ;;
        $LOG_INFO)  [[ $CURRENT_LOG_LEVEL -le $LOG_INFO ]]  && echo -e "${GREEN}[INFO]${NC} $msg" ;;
        $LOG_WARN)  [[ $CURRENT_LOG_LEVEL -le $LOG_WARN ]]  && echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        $LOG_ERROR) [[ $CURRENT_LOG_LEVEL -le $LOG_ERROR ]] && echo -e "${RED}[ERROR]${NC} $msg" ;;
    esac
    [[ $LOG_JSON != true ]] && echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}
debug() { _log $LOG_DEBUG "$1"; }
info()  { _log $LOG_INFO "$1"; }
warn()  { _log $LOG_WARN "$1"; }
error() { _log $LOG_ERROR "$1"; }

# ─── Helpers ───────────────────────────────────────────────────────────────
run_cmd() {
    local desc=$1
    shift
    local cmd=("$@")
    [[ $DRY_RUN == true ]] && { info "[DRY-RUN] $desc"; return 0; }
    debug "Running: ${cmd[*]}"
    "${cmd[@]}" >> "$LOG_FILE" 2>&1 && { debug "OK: $desc"; return 0; } || {
        error "Failed: $desc (code $?)"; return 1; }
}

run_cmd_shell() {
    local desc=$1
    local cmd=$2
    [[ $DRY_RUN == true ]] && { info "[DRY-RUN] $desc"; return 0; }
    debug "Running: $cmd"
    bash -c "$cmd" >> "$LOG_FILE" 2>&1 && { debug "OK: $desc"; return 0; } || {
        error "Failed: $desc (code $?)"; return 1; }
}

retry_cmd() {
    local max=3 delay=2 i=1 desc=$1
    shift
    local cmd=("$@")
    while (( i <= max )); do
        run_cmd "$desc (try $i/$max)" "${cmd[@]}" && return 0
        (( i < max )) && { warn "Retry in ${delay}s..."; sleep $delay; delay=$((delay*2)); }
        ((i++))
    done
    error "Gave up after $max tries: $desc"; return 1
}

retry_cmd_shell() {
    local max=3 delay=2 i=1 desc=$1
    shift
    local cmd=$1
    while (( i <= max )); do
        run_cmd_shell "$desc (try $i/$max)" "$cmd" && return 0
        (( i < max )) && { warn "Retry in ${delay}s..."; sleep $delay; delay=$((delay*2)); }
        ((i++))
    done
    error "Gave up after $max tries: $desc"; return 1
}

check_root() { [[ $SKIP_ROOT_CHECK == true ]] && return 0; (( EUID != 0 )) && { error "Need root (sudo)"; exit 1; }; }
detect_os() {
    local id="" version_id="" pretty_name=""
    if [[ -r /etc/os-release ]]; then
        id=$(grep '^ID=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')
        version_id=$(grep '^VERSION_ID=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')
        pretty_name=$(grep '^PRETTY_NAME=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')
    fi
    [[ -z $id ]] && { error "Unknown OS (cannot parse /etc/os-release)"; exit 1; }
    export OS_ID=$id OS_VERSION_ID=$version_id OS_PRETTY_NAME=$pretty_name
}

check_os() {
    [[ $SKIP_OS_CHECK == true ]] && { info "Skipping OS check"; return 0; }
    detect_os
    case $OS_ID in
        ubuntu|debian) info "OS: $OS_PRETTY_NAME" ;;
        *) warn "Untested on $OS_ID ($OS_PRETTY_NAME)" ;;
    esac
}

# ─── Package Install ───────────────────────────────────────────────────────
get_pkg_manager() {
    case $OS_ID in
        ubuntu|debian) echo "apt-get" ;;
        rhel|fedora)   echo "dnf" ;;
        alpine)        echo "apk" ;;
        *)             echo "apt-get" ;;
    esac
}

install_packages() {
    [[ $SKIP_PACKAGES == true ]] && { info "Skipping package install (SKIP_PACKAGES)"; return 0; }
    check_os
    local pkg_mgr
    pkg_mgr=$(get_pkg_manager)
    local packages="${REQUIRED_PACKAGES[$OS_ID]:-${REQUIRED_PACKAGES[debian]}}"
    info "Installing: $packages (via $pkg_mgr)"
    case $pkg_mgr in
        apt-get)
            run_cmd "apt update" apt-get update -y || return 1
            run_cmd "apt install packages" apt-get install -y $packages || return 1
            ;;
        dnf)
            run_cmd "dnf install packages" dnf install -y $packages || return 1
            ;;
        apk)
            run_cmd "apk update" apk update || return 1
            run_cmd "apk add packages" apk add $packages || return 1
            ;;
    esac
    info "Packages done"
}

# ─── Server Info ───────────────────────────────────────────────────────────
get_server_info() {
    [[ $SKIP_SERVER_INFO == true ]] && {
        info "Skipping server info (SKIP_SERVER_INFO)"
        export SERVER_IP="127.0.0.1" SERVER_COUNTRY="Test" SERVER_ISP="Test"
        return 0
    }
    info "Getting server info..."

    # Robust IP detection with fallback
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    fi
    [[ -z $ip ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z $ip ]] && { error "No IP found"; return 1; }
    info "IP: $ip"

    # Single curl call for both country and isp
    local country="" isp="" geo_json=""
    geo_json=$(curl -sS --max-time 10 "http://ip-api.com/json/$ip?fields=country,isp" 2>/dev/null) || true
    if [[ -n $geo_json ]]; then
        country=$(echo "$geo_json" | jq -r '.country // empty' 2>/dev/null) || country=""
        isp=$(echo "$geo_json" | jq -r '.isp // empty' 2>/dev/null) || isp=""
    fi

    if [[ -z $country || -z $isp ]]; then
        debug "ip-api failed, trying ipinfo.io..."
        local fb
        fb=$(curl -sS --max-time 10 "https://ipinfo.io/$ip/json" 2>/dev/null) || fb=""
        [[ -n $fb ]] && {
            country=${country:-$(echo "$fb" | jq -r '.country // empty' 2>/dev/null)}
            isp=${isp:-$(echo "$fb" | jq -r '.org // empty' 2>/dev/null)}
        }
    fi

    country=${country:-Unknown}
    isp=${isp:-Unknown}
    info "Country: $country | ISP: $isp"
    export SERVER_IP=$ip SERVER_COUNTRY=$country SERVER_ISP=$isp
}

# ─── Template Handling ─────────────────────────────────────────────────────
verify_checksum() {
    local file=$1 expected=$2
    [[ -z $expected ]] && { warn "No checksum provided, skipping verification"; return 0; }
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    [[ $actual == "$expected" ]] || { error "Checksum mismatch: expected $expected, got $actual"; return 1; }
    info "Checksum verified"
}

download_template() {
    [[ $SKIP_TEMPLATE == true ]] && { info "Skipping template (SKIP_TEMPLATE)"; return 0; }
    [[ $DRY_RUN == true ]] && {
        info "[DRY-RUN] Would download $TEMPLATE_REPO@$TEMPLATE_BRANCH"
        export TEMPLATE_DIR="$WORK_DIR/website-templates-$TEMPLATE_BRANCH"
        info "Template at: $TEMPLATE_DIR (dry-run)"
        return 0
    }
    info "Downloading $TEMPLATE_REPO@$TEMPLATE_BRANCH"
    local url="https://github.com/$TEMPLATE_REPO/archive/refs/heads/$TEMPLATE_BRANCH.zip"
    local zip="$WORK_DIR/template-$TEMPLATE_BRANCH.zip"
    run_cmd_shell "Cleanup" "rm -rf \"$WORK_DIR/website-templates-\"\"*\" \"$zip\""
    retry_cmd_shell "Download" "curl -fsSL -o \"$zip\" \"$url\"" || return 1
    [[ -s $zip ]] || { error "Empty zip"; return 1; }

    # Verify checksum if provided
    local expected_checksum="${TEMPLATE_SHA256:-}"
    verify_checksum "$zip" "$expected_checksum" || return 1

    run_cmd_shell "Unzip" "cd \"$WORK_DIR\" && unzip -q \"$zip\"" || return 1
    local dir
    # Find newest matching directory
    dir=$(find "$WORK_DIR" -maxdepth 1 -type d -name 'website-templates-*' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    [[ -z $dir ]] && { error "Template dir missing"; return 1; }
    export TEMPLATE_DIR=$dir
    info "Template at: $TEMPLATE_DIR"
}

cleanup_template() {
    info "Removing junk from template..."
    local patterns=("assets" ".gitattributes" "README.md" "_config.yml" "LICENSE*")
    # Use find with multiple -name predicates combined with -o
    run_cmd_shell "Cleanup template" "find \"$TEMPLATE_DIR\" \( -name 'assets' -o -name '.gitattributes' -o -name 'README.md' -o -name '_config.yml' -o -name 'LICENSE*' \) -exec rm -rf {} +" || true
    # Remove .md files separately (glob in find)
    run_cmd_shell "Remove .md files" "find \"$TEMPLATE_DIR\" -name '*.md' -exec rm -f {} +" || true
}

select_random_template() {
    info "Picking random template..."
    [[ $DRY_RUN == true ]] && {
        export SELECTED_TEMPLATE="$TEMPLATE_DIR/template-1"
        export TEMPLATE_NAME="template-1"
        info "Using: $TEMPLATE_NAME (dry-run)"
        return 0
    }
    local arr=()
    # Use mapfile to avoid subshell (bash 4.4+)
    if [[ ${BASH_VERSINFO[0]} -ge 4 && ${BASH_VERSINFO[1]} -ge 4 ]]; then
        mapfile -d '' arr < <(find "$TEMPLATE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    else
        # Fallback for older bash
        while IFS= read -r -d '' d; do [[ -d $d ]] && arr+=("$d"); done < <(find "$TEMPLATE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
    (( ${#arr[@]} == 0 )) && { error "No templates found in $TEMPLATE_DIR"; return 1; }
    local pick=${arr[$((RANDOM % ${#arr[@]}))]}
    export SELECTED_TEMPLATE=$pick
    export TEMPLATE_NAME=$(basename "$pick")
    info "Using: $TEMPLATE_NAME"
}

deploy_template() {
    info "Deploying to $WEB_ROOT..."
    [[ -d $WEB_ROOT ]] || run_cmd "mkdir webroot" mkdir -p "$WEB_ROOT" || return 1
    if [[ -n $(ls -A "$WEB_ROOT" 2>/dev/null) ]]; then
        local backup_path="${WEB_ROOT}.backup.$(date +%s)"
        run_cmd "backup old" mv "$WEB_ROOT" "$backup_path" || true
        run_cmd "recreate webroot" mkdir -p "$WEB_ROOT" || return 1
    fi
    run_cmd "copy files" cp -a "$SELECTED_TEMPLATE/." "$WEB_ROOT/" || return 1

    # Detect web user
    local web_user="www-data"
    id "$web_user" >/dev/null 2>&1 || web_user="nginx"
    id "$web_user" >/dev/null 2>&1 || web_user="apache"
    run_cmd "fix owner" chown -R "$web_user:$web_user" "$WEB_ROOT" || true
    run_cmd "file perms" find "$WEB_ROOT" -type f -exec chmod 644 {} + || true
    run_cmd "dir perms" find "$WEB_ROOT" -type d -exec chmod 755 {} + || true
    info "Deployed: $TEMPLATE_NAME"
}

# ─── Nginx ─────────────────────────────────────────────────────────────────
configure_nginx() {
    info "Setting up Nginx..."
    run_cmd "test config" nginx -t || return 1
    run_cmd "enable" systemctl enable nginx || true
    run_cmd "restart" systemctl restart nginx || return 1

    # Health check
    sleep 2
    if curl -sf --max-time 5 http://localhost/ >/dev/null 2>&1; then
        info "Nginx health check passed"
    else
        warn "Nginx health check failed (may still be starting)"
    fi
    info "Nginx up"
}

# Initialize log file early (before any logging)
if [[ $DRY_RUN != true ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/direct-setup.log"
    : > "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/direct-setup.log"
fi

# ─── Main ──────────────────────────────────────────────────────────────────
main() {
    info "=== $SCRIPT_NAME v$SCRIPT_VERSION ==="
    info "Repo: $TEMPLATE_REPO  Branch: $TEMPLATE_BRANCH  Root: $WEB_ROOT"
    [[ $DRY_RUN == true ]] && warn "DRY RUN - no changes"
    check_root
    check_os
    install_packages || exit 1

    # Validate preconditions after SKIP flags
    if [[ $SKIP_PACKAGES == true ]]; then
        command -v nginx >/dev/null 2>&1 || { error "SKIP_PACKAGES=true but nginx not installed"; exit 1; }
        command -v jq >/dev/null 2>&1 || { error "SKIP_PACKAGES=true but jq not installed"; exit 1; }
        command -v unzip >/dev/null 2>&1 || { error "SKIP_PACKAGES=true but unzip not installed"; exit 1; }
        command -v curl >/dev/null 2>&1 || { error "SKIP_PACKAGES=true but curl not installed"; exit 1; }
    fi

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
  SKIP_ROOT_CHECK    Skip root check (default: false)
  SKIP_OS_CHECK      Skip OS check (default: false)
  SKIP_SERVER_INFO   Skip server info (default: false)
  DRY_RUN            Test run, no changes (default: false)
  LOG_LEVEL          0=DEBUG 1=INFO 2=WARN 3=ERROR (default: 1)
  LOG_JSON           JSON structured logging (default: false)
  TEMPLATE_SHA256    Expected SHA256 of template zip (optional)

Examples:
  TEMPLATE_REPO="me/myrepo" bash <(curl -s ...)
  SKIP_TEMPLATE=true bash <(curl -s ...)
  DRY_RUN=true bash <(curl -s ...)
  TEMPLATE_SHA256="abc123..." bash <(curl -s ...)
  LOG_JSON=true LOG_LEVEL=0 bash <(curl -s ...)
EOF
}
case ${1:-} in -h|--help) show_help; exit 0;; -v|--version) echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0;; esac
main "$@"