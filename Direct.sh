#!/usr/bin/env bash
#
# Direct.sh - VPS Configuration Script for Direct Configs
# Refactored version with better error handling, logging, and configurability
#
# Usage: bash <(curl -s https://raw.githubusercontent.com/Salarvand-Education/Direct/main/Direct.sh)
#        TEMPLATE_REPO="user/repo" TEMPLATE_BRANCH="main" bash <(curl -s ...)

set -euo pipefail

# =============================================================================
# Configuration (can be overridden via environment variables)
# =============================================================================
readonly SCRIPT_NAME="Direct.sh"
readonly SCRIPT_VERSION="2.0.0"
readonly DEFAULT_TEMPLATE_REPO="Salarvand-Education/website-templates"
readonly DEFAULT_TEMPLATE_BRANCH="main"
readonly DEFAULT_WEB_ROOT="/var/www/html"
readonly DEFAULT_WORK_DIR="/root"
readonly LOG_FILE="/var/log/direct-setup.log"

# User-configurable via environment
TEMPLATE_REPO="${TEMPLATE_REPO:-$DEFAULT_TEMPLATE_REPO}"
TEMPLATE_BRANCH="${TEMPLATE_BRANCH:-$DEFAULT_TEMPLATE_BRANCH}"
WEB_ROOT="${WEB_ROOT:-$DEFAULT_WEB_ROOT}"
WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"
SKIP_PACKAGES="${SKIP_PACKAGES:-false}"
SKIP_TEMPLATE="${SKIP_TEMPLATE:-false}"
DRY_RUN="${DRY_RUN:-false}"

# Required packages
readonly REQUIRED_PACKAGES=("jq" "unzip" "nginx" "curl")

# =============================================================================
# Color Codes & Output Functions
# =============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Log levels
readonly LOG_DEBUG=0
readonly LOG_INFO=1
readonly LOG_WARN=2
readonly LOG_ERROR=3
CURRENT_LOG_LEVEL=${LOG_LEVEL:-$LOG_INFO}

# =============================================================================
# Logging Functions
# =============================================================================
_log() {
    local level=$1
    local msg=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Console output with colors
    case $level in
        $LOG_DEBUG) [[ $CURRENT_LOG_LEVEL -le $LOG_DEBUG ]] && echo -e "${BLUE}[DEBUG]${NC} $msg" ;;
        $LOG_INFO)  [[ $CURRENT_LOG_LEVEL -le $LOG_INFO ]]  && echo -e "${GREEN}[INFO]${NC} $msg" ;;
        $LOG_WARN)  [[ $CURRENT_LOG_LEVEL -le $LOG_WARN ]]  && echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        $LOG_ERROR) [[ $CURRENT_LOG_LEVEL -le $LOG_ERROR ]] && echo -e "${RED}[ERROR]${NC} $msg" ;;
    esac

    # File logging (always)
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

debug() { _log $LOG_DEBUG "$1"; }
info()  { _log $LOG_INFO "$1"; }
warn()  { _log $LOG_WARN "$1"; }
error() { _log $LOG_ERROR "$1"; }

# =============================================================================
# Utility Functions
# =============================================================================
run_cmd() {
    local cmd="$1"
    local description="${2:-$cmd}"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] $description"
        return 0
    fi

    debug "Executing: $cmd"
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        debug "Success: $description"
        return 0
    else
        local exit_code=$?
        error "Failed: $description (exit code: $exit_code)"
        return $exit_code
    fi
}

retry_cmd() {
    local max_attempts=3
    local delay=2
    local attempt=1
    local cmd="$1"
    local description="${2:-$cmd}"

    while [[ $attempt -le $max_attempts ]]; do
        if run_cmd "$cmd" "$description (attempt $attempt/$max_attempts)"; then
            return 0
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            warn "Retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))
        fi
        ((attempt++))
    done
    error "Failed after $max_attempts attempts: $description"
    return 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect OS. This script supports Debian/Ubuntu based systems."
        exit 1
    fi
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        warn "OS '$ID' not officially supported. Proceeding anyway..."
    fi
    info "Detected OS: $PRETTY_NAME"
}

# =============================================================================
# Package Management
# =============================================================================
install_packages() {
    [[ "$SKIP_PACKAGES" == "true" ]] && { info "Skipping package installation (SKIP_PACKAGES=true)"; return 0; }

    info "Installing required packages: ${REQUIRED_PACKAGES[*]}"

    run_cmd "apt-get update -y" "Update package index" || return 1

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if command -v "$pkg" &>/dev/null; then
            info "$pkg is already installed"
        else
            info "Installing $pkg..."
            run_cmd "apt-get install -y $pkg" "Install $pkg" || return 1
        fi
    done

    info "All packages installed successfully"
}

# =============================================================================
# Server Information
# =============================================================================
get_server_info() {
    info "Gathering server information..."

    local server_ip
    server_ip=$(hostname -I | awk '{print $1}') || {
        error "Could not determine server IP address"
        return 1
    }

    [[ -z "$server_ip" ]] && { error "Empty server IP"; return 1; }

    info "Server IP: $server_ip"

    # Try multiple IP geolocation services
    local country="" isp=""

    # Primary: ip-api.com
    if country=$(curl -sS --max-time 10 "http://ip-api.com/json/$server_ip?fields=country,isp" 2>/dev/null | jq -r '.country // empty' 2>/dev/null); then
        isp=$(curl -sS --max-time 10 "http://ip-api.com/json/$server_ip?fields=country,isp" 2>/dev/null | jq -r '.isp // empty' 2>/dev/null)
    fi

    # Fallback: ipinfo.io
    if [[ -z "$country" || -z "$isp" ]]; then
        debug "Trying fallback service ipinfo.io..."
        local fallback
        fallback=$(curl -sS --max-time 10 "https://ipinfo.io/$server_ip/json" 2>/dev/null) || true
        country="${country:-$(echo "$fallback" | jq -r '.country // empty' 2>/dev/null)}"
        isp="${isp:-$(echo "$fallback" | jq -r '.org // empty' 2>/dev/null)}"
    fi

    [[ -z "$country" ]] && country="Unknown"
    [[ -z "$isp" ]] && isp="Unknown"

    info "Country: $country"
    info "ISP: $isp"

    # Export for other functions
    export SERVER_IP="$server_ip"
    export SERVER_COUNTRY="$country"
    export SERVER_ISP="$isp"
}

# =============================================================================
# Template Management
# =============================================================================
download_template() {
    [[ "$SKIP_TEMPLATE" == "true" ]] && { info "Skipping template setup (SKIP_TEMPLATE=true)"; return 0; }

    info "Downloading template from $TEMPLATE_REPO@$TEMPLATE_BRANCH"

    local zip_url="https://github.com/$TEMPLATE_REPO/archive/refs/heads/$TEMPLATE_BRANCH.zip"
    local zip_file="$WORK_DIR/template-$TEMPLATE_BRANCH.zip"
    local extract_dir="$WORK_DIR/website-templates-$TEMPLATE_BRANCH"

    # Cleanup any previous runs
    run_cmd "rm -rf '$extract_dir' '$zip_file'" "Cleanup previous template files"

    # Download with retry
    retry_cmd "curl -fsSL -o '$zip_file' '$zip_url'" "Download template archive" || return 1

    # Verify download
    [[ -s "$zip_file" ]] || { error "Downloaded file is empty"; return 1; }

    info "Extracting template..."
    run_cmd "cd '$WORK_DIR' && unzip -q '$zip_file'" "Extract template" || return 1

    # Find the extracted directory (handles different naming)
    local actual_dir
    actual_dir=$(find "$WORK_DIR" -maxdepth 1 -type d -name "website-templates-*" | head -1)
    [[ -z "$actual_dir" ]] && { error "Could not find extracted template directory"; return 1; }

    export TEMPLATE_DIR="$actual_dir"
    info "Template extracted to: $TEMPLATE_DIR"
}

cleanup_template() {
    info "Cleaning up template files..."
    local patterns=("assets" ".gitattributes" "README.md" "_config.yml" "*.md" "LICENSE*")

    for pattern in "${patterns[@]}"; do
        run_cmd "find '$TEMPLATE_DIR' -name '$pattern' -exec rm -rf {} +" "Remove $pattern" || true
    done
}

select_random_template() {
    info "Selecting random template..."

    local templates=()
    while IFS= read -r -d '' dir; do
        [[ -d "$dir" ]] && templates+=("$dir")
    done < <(find "$TEMPLATE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

    [[ ${#templates[@]} -eq 0 ]] && { error "No template directories found"; return 1; }

    local random_index=$((RANDOM % ${#templates[@]}))
    local selected="${templates[$random_index]}"
    local template_name
    template_name=$(basename "$selected")

    info "Selected template: $template_name"
    export SELECTED_TEMPLATE="$selected"
    export TEMPLATE_NAME="$template_name"
}

deploy_template() {
    info "Deploying template to $WEB_ROOT..."

    [[ -d "$WEB_ROOT" ]] || run_cmd "mkdir -p '$WEB_ROOT'" "Create web root directory" || return 1

    # Backup existing content (optional)
    if [[ -n "$(ls -A "$WEB_ROOT" 2>/dev/null)" ]]; then
        local backup_dir="/var/www/html.backup.$(date +%s)"
        run_cmd "mv '$WEB_ROOT' '$backup_dir'" "Backup existing web content" || true
        run_cmd "mkdir -p '$WEB_ROOT'" "Recreate web root" || return 1
    fi

    run_cmd "cp -a '$SELECTED_TEMPLATE/.' '$WEB_ROOT/'" "Copy template to web root" || return 1

    # Set proper permissions
    run_cmd "chown -R www-data:www-data '$WEB_ROOT'" "Set web root ownership" || true
    run_cmd "find '$WEB_ROOT' -type f -exec chmod 644 {} +" "Set file permissions" || true
    run_cmd "find '$WEB_ROOT' -type d -exec chmod 755 {} +" "Set directory permissions" || true

    info "Template deployed successfully: $TEMPLATE_NAME"
}

# =============================================================================
# Nginx Configuration
# =============================================================================
configure_nginx() {
    info "Configuring Nginx..."

    # Test nginx config
    run_cmd "nginx -t" "Test Nginx configuration" || return 1

    # Enable and start nginx
    run_cmd "systemctl enable nginx" "Enable Nginx service" || true
    run_cmd "systemctl restart nginx" "Restart Nginx" || return 1

    info "Nginx configured and running"
}

# =============================================================================
# Main Execution
# =============================================================================
main() {
    # Initialize log file
    : > "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/direct-setup.log"
    : > "$LOG_FILE"

    info "=== $SCRIPT_NAME v$SCRIPT_VERSION ==="
    info "Starting VPS configuration for direct configs"
    info "Log file: $LOG_FILE"
    info "Configuration: TEMPLATE_REPO=$TEMPLATE_REPO, TEMPLATE_BRANCH=$TEMPLATE_BRANCH, WEB_ROOT=$WEB_ROOT"

    [[ "$DRY_RUN" == "true" ]] && warn "DRY RUN MODE - No changes will be made"

    # Pre-flight checks
    check_root
    check_os

    # Execution steps
    install_packages || exit 1
    get_server_info || exit 1

    if [[ "$SKIP_TEMPLATE" != "true" ]]; then
        download_template || exit 1
        cleanup_template || exit 1
        select_random_template || exit 1
        deploy_template || exit 1
    fi

    configure_nginx || exit 1

    info "=== All operations completed successfully! ==="
    info "Server IP: $SERVER_IP"
    info "Country: $SERVER_COUNTRY"
    info "ISP: $SERVER_ISP"
    [[ "$SKIP_TEMPLATE" != "true" ]] && info "Deployed template: $TEMPLATE_NAME"
    info "Web root: $WEB_ROOT"
    info "Nginx status: $(systemctl is-active nginx 2>/dev/null || echo 'unknown')"
}

# =============================================================================
# Help & Entry Point
# =============================================================================
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - VPS Configuration for Direct Configs

Usage:
  bash <(curl -s https://raw.githubusercontent.com/Salarvand-Education/Direct/main/Direct.sh)

  # With custom options:
  TEMPLATE_REPO="user/repo" TEMPLATE_BRANCH="main" bash <(curl -s ...)
  SKIP_PACKAGES=true SKIP_TEMPLATE=true bash <(curl -s ...)
  DRY_RUN=true bash <(curl -s ...)

Environment Variables:
  TEMPLATE_REPO      GitHub repo for templates (default: $DEFAULT_TEMPLATE_REPO)
  TEMPLATE_BRANCH    Branch to use (default: $DEFAULT_TEMPLATE_BRANCH)
  WEB_ROOT           Web root directory (default: $DEFAULT_WEB_ROOT)
  WORK_DIR           Working directory (default: $DEFAULT_WORK_DIR)
  SKIP_PACKAGES      Skip package installation (default: false)
  SKIP_TEMPLATE      Skip template deployment (default: false)
  DRY_RUN            Run without making changes (default: false)
  LOG_LEVEL          Log level: 0=DEBUG, 1=INFO, 2=WARN, 3=ERROR (default: 1)

Examples:
  # Use custom template repo
  TEMPLATE_REPO="myorg/my-templates" bash <(curl -s ...)

  # Only configure nginx, skip template
  SKIP_TEMPLATE=true bash <(curl -s ...)

  # Test run without changes
  DRY_RUN=true bash <(curl -s ...)
EOF
}

# Handle arguments
case "${1:-}" in
    -h|--help) show_help; exit 0 ;;
    -v|--version) echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
esac

# Run main
main "$@"