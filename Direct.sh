#!/usr/bin/env bash
#
# Direct.sh - VPS setup for direct configs
#
# Installs nginx and deploys a random static website template to the web root.
# Run with --help for the list of environment variables.

set -euo pipefail

# ─── Constants & configuration ──────────────────────────────────────────────

readonly SCRIPT_NAME="Direct.sh"
readonly SCRIPT_VERSION="2.2.0"
readonly RAW_URL="https://raw.githubusercontent.com/Salarvand-Education/Direct/main/Direct.sh"

readonly DEFAULT_TEMPLATE_REPO="Salarvand-Education/website-templates"
readonly DEFAULT_TEMPLATE_BRANCH="HEAD"   # HEAD = the repo's default branch (it is "master", not "main")
readonly DEFAULT_WEB_ROOT="/var/www/html"
readonly DEFAULT_LOG_FILE="/var/log/direct-setup.log"

# Overridable via environment
TEMPLATE_REPO="${TEMPLATE_REPO:-$DEFAULT_TEMPLATE_REPO}"
TEMPLATE_BRANCH="${TEMPLATE_BRANCH:-$DEFAULT_TEMPLATE_BRANCH}"   # HEAD, branch, tag or commit
TEMPLATE_SHA256="${TEMPLATE_SHA256:-}"
WEB_ROOT="${WEB_ROOT:-$DEFAULT_WEB_ROOT}"
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}}"
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
LOG_LEVEL="${LOG_LEVEL:-1}"
LOG_JSON="${LOG_JSON:-false}"
SKIP_PACKAGES="${SKIP_PACKAGES:-false}"
SKIP_TEMPLATE="${SKIP_TEMPLATE:-false}"
SKIP_ROOT_CHECK="${SKIP_ROOT_CHECK:-false}"
SKIP_OS_CHECK="${SKIP_OS_CHECK:-false}"
SKIP_SERVER_INFO="${SKIP_SERVER_INFO:-false}"
DRY_RUN="${DRY_RUN:-false}"

readonly -a PACKAGES=(nginx curl jq unzip)

# Runtime state
TMP_DIR=""
LOG_READY=false
TEMPLATE_DIR=""
SELECTED_TEMPLATE=""
TEMPLATE_NAME=""
SERVER_IP="Unknown"
SERVER_COUNTRY="Unknown"
SERVER_ISP="Unknown"

# ─── Logging ────────────────────────────────────────────────────────────────

readonly LOG_DEBUG=0 LOG_INFO=1 LOG_WARN=2 LOG_ERROR=3
readonly -a LEVEL_NAMES=(DEBUG INFO WARN ERROR)

if [[ -t 1 ]]; then
  readonly -a LEVEL_COLORS=($'\033[0;34m' $'\033[0;32m' $'\033[0;33m' $'\033[0;31m')
  readonly NC=$'\033[0m'
else
  readonly -a LEVEL_COLORS=('' '' '' '')
  readonly NC=''
fi

# A bad LOG_LEVEL would break the arithmetic in log(), so sanitize it first.
[[ $LOG_LEVEL =~ ^[0-3]$ ]] || LOG_LEVEL=$LOG_INFO

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

log() {
  local level=$1
  shift
  local msg="$*"
  local name=${LEVEL_NAMES[$level]}

  # The log file always receives every level; the console is filtered.
  if [[ $LOG_READY == true ]]; then
    if [[ $LOG_JSON == true ]]; then
      printf '{"timestamp":"%s","level":"%s","message":"%s"}\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$name" "$(json_escape "$msg")"
    else
      printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$name" "$msg"
    fi >>"$LOG_FILE" 2>/dev/null || true
  fi

  (( level >= LOG_LEVEL )) || return 0
  if (( level >= LOG_WARN )); then
    printf '%s[%s]%s %s\n' "${LEVEL_COLORS[level]}" "$name" "$NC" "$msg" >&2
  else
    printf '%s[%s]%s %s\n' "${LEVEL_COLORS[level]}" "$name" "$NC" "$msg"
  fi
}

debug() { log "$LOG_DEBUG" "$*"; }
info()  { log "$LOG_INFO" "$*"; }
warn()  { log "$LOG_WARN" "$*"; }
error() { log "$LOG_ERROR" "$*"; }
die()   { error "$*"; exit 1; }

init_logging() {
  if [[ $DRY_RUN == true ]]; then
    return 0
  fi
  if ! { mkdir -p "$(dirname "$LOG_FILE")" && touch "$LOG_FILE"; } 2>/dev/null; then
    LOG_FILE="/tmp/direct-setup.log"
    touch "$LOG_FILE" 2>/dev/null || return 0
  fi
  LOG_READY=true
}

cleanup() {
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
    rm -rf "$TMP_DIR"
  fi
}

# ─── Command helpers ────────────────────────────────────────────────────────

# run <description> <command> [args...]
# Runs a command (no shell, so no quoting problems), logs its output to the log
# file and honors DRY_RUN.
run() {
  local desc=$1
  shift
  if [[ $DRY_RUN == true ]]; then
    info "[DRY-RUN] $desc"
    return 0
  fi
  debug "Running: $*"
  if "$@" >>"$LOG_FILE" 2>&1; then
    debug "OK: $desc"
  else
    local rc=$?
    error "Failed: $desc (exit $rc) - see $LOG_FILE"
    return "$rc"
  fi
}

# retry <description> <command> [args...]  (3 tries, exponential backoff)
retry() {
  local desc=$1
  shift
  local max=3 delay=2 attempt
  for (( attempt = 1; attempt <= max; attempt++ )); do
    run "$desc (try $attempt/$max)" "$@" && return 0
    if (( attempt < max )); then
      warn "Retrying in ${delay}s..."
      sleep "$delay"
      delay=$(( delay * 2 ))
    fi
  done
  error "Gave up after $max tries: $desc"
  return 1
}

# ─── Validation & environment checks ────────────────────────────────────────

validate_config() {
  [[ $TEMPLATE_REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || die "Invalid TEMPLATE_REPO: '$TEMPLATE_REPO' (expected owner/name)"
  [[ $TEMPLATE_BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] \
    || die "Invalid TEMPLATE_BRANCH: '$TEMPLATE_BRANCH'"

  # The existing web root is moved away during deploy, so refuse dangerous paths.
  WEB_ROOT=${WEB_ROOT%/}
  case $WEB_ROOT in
    ""|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var)
      die "Refusing unsafe WEB_ROOT: '${WEB_ROOT:-/}'" ;;
    /*) ;;
    *) die "WEB_ROOT must be an absolute path: '$WEB_ROOT'" ;;
  esac
}

check_root() {
  if [[ $SKIP_ROOT_CHECK == true || $DRY_RUN == true ]]; then
    return 0
  fi
  (( EUID == 0 )) || die "Need root (try sudo)"
}

check_os() {
  if [[ $SKIP_OS_CHECK == true ]]; then
    info "Skipping OS check"
    return 0
  fi

  local id="" like="" name="unknown"
  if [[ -r /etc/os-release ]]; then
    IFS='|' read -r id like name < <(
      # shellcheck disable=SC1091
      . /etc/os-release
      printf '%s|%s|%s\n' "${ID:-}" "${ID_LIKE:-}" "${PRETTY_NAME:-unknown}"
    ) || true
  fi

  case " $id $like " in
    *" debian "*|*" ubuntu "*)
      info "OS: $name" ;;
    *)
      warn "Only Debian/Ubuntu are tested (found: $name). nginx's default web root differs there, so you may need to point nginx at $WEB_ROOT yourself." ;;
  esac
}

# ─── Packages ───────────────────────────────────────────────────────────────

install_packages() {
  if [[ $SKIP_PACKAGES == true ]]; then
    info "Skipping package install (SKIP_PACKAGES=true)"
    local cmd
    for cmd in "${PACKAGES[@]}"; do
      command -v "$cmd" >/dev/null 2>&1 \
        || die "SKIP_PACKAGES=true but '$cmd' is not installed"
    done
    return 0
  fi

  info "Installing: ${PACKAGES[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    retry "apt update" apt-get update
    retry "apt install" apt-get install -y "${PACKAGES[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    retry "dnf install" dnf install -y "${PACKAGES[@]}"
  elif command -v apk >/dev/null 2>&1; then
    retry "apk add" apk add --no-cache "${PACKAGES[@]}"
  else
    die "No supported package manager (apt-get, dnf, apk). Install ${PACKAGES[*]} yourself and set SKIP_PACKAGES=true"
  fi
  info "Packages done"
}

# ─── Server info (informational only, never fatal) ──────────────────────────

lookup_geo() {
  local json

  if json=$(curl -fsS --max-time 10 'http://ip-api.com/json/?fields=status,query,country,isp' 2>/dev/null) \
      && [[ $(jq -r '.status // empty' <<<"$json" 2>/dev/null) == success ]]; then
    SERVER_IP=$(jq -r '.query // "Unknown"' <<<"$json")
    SERVER_COUNTRY=$(jq -r '.country // "Unknown"' <<<"$json")
    SERVER_ISP=$(jq -r '.isp // "Unknown"' <<<"$json")
    return 0
  fi

  debug "ip-api failed, trying ipinfo.io..."
  if json=$(curl -fsS --max-time 10 'https://ipinfo.io/json' 2>/dev/null) \
      && jq -e '.ip' <<<"$json" >/dev/null 2>&1; then
    SERVER_IP=$(jq -r '.ip' <<<"$json")
    SERVER_COUNTRY=$(jq -r '.country // "Unknown"' <<<"$json")
    SERVER_ISP=$(jq -r '.org // "Unknown"' <<<"$json")
    return 0
  fi

  return 1
}

get_server_info() {
  if [[ $SKIP_SERVER_INFO == true ]]; then
    info "Skipping server info (SKIP_SERVER_INFO=true)"
    SERVER_IP="127.0.0.1"
    SERVER_COUNTRY="Test"
    SERVER_ISP="Test"
    return 0
  fi

  info "Getting server info..."
  if command -v jq >/dev/null 2>&1; then
    # No IP is passed on purpose: the services report the caller's *public* IP,
    # which differs from the local one on NATed VPSes.
    lookup_geo || warn "Geo lookup failed; continuing without it"
  else
    warn "jq not available; skipping geo lookup"
  fi

  if [[ $SERVER_IP == Unknown ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    SERVER_IP=${SERVER_IP:-Unknown}
  fi
  info "IP: $SERVER_IP | Country: $SERVER_COUNTRY | ISP: $SERVER_ISP"
}

# ─── Template handling ──────────────────────────────────────────────────────

verify_checksum() {
  local file=$1 expected=${2,,} actual
  if [[ -z $expected ]]; then
    warn "TEMPLATE_SHA256 not set; skipping checksum verification"
    return 0
  fi
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die "Checksum mismatch: expected $expected, got $actual"
  info "Checksum verified"
}

download_template() {
  local url="https://github.com/${TEMPLATE_REPO}/archive/${TEMPLATE_BRANCH}.zip"
  info "Downloading $TEMPLATE_REPO@$TEMPLATE_BRANCH"

  if [[ $DRY_RUN == true ]]; then
    info "[DRY-RUN] Would download $url"
    TEMPLATE_DIR="(dry-run)"
    return 0
  fi

  mkdir -p "$WORK_DIR"
  TMP_DIR=$(mktemp -d "${WORK_DIR%/}/direct.XXXXXX")
  local zip="$TMP_DIR/template.zip" extract="$TMP_DIR/extract"

  retry "Download template" curl -fsSL --connect-timeout 15 --max-time 180 -o "$zip" "$url"
  [[ -s $zip ]] || die "Downloaded archive is empty"
  verify_checksum "$zip" "$TEMPLATE_SHA256"

  mkdir -p "$extract"
  run "Unzip template" unzip -q "$zip" -d "$extract"

  # A GitHub archive always contains exactly one top-level directory
  # (<repo>-<ref>), whatever TEMPLATE_REPO / TEMPLATE_BRANCH are.
  local -a entries=("$extract"/*/)
  [[ ${#entries[@]} -eq 1 && -d ${entries[0]} ]] \
    || die "Unexpected archive layout (expected one top-level directory)"
  TEMPLATE_DIR=${entries[0]%/}
  info "Template at: $TEMPLATE_DIR"
}

cleanup_template() {
  info "Removing non-template files..."
  # Only top-level repo clutter is removed, so a template's own files survive.
  run "Remove repo clutter" find "$TEMPLATE_DIR" -mindepth 1 -maxdepth 1 \
    \( -name assets -o -name '.*' -o -iname 'README*' -o -name '_config.yml' -o -iname 'LICENSE*' \) \
    -exec rm -rf {} +
  run "Remove markdown files" find "$TEMPLATE_DIR" -type f -name '*.md' -delete
}

select_random_template() {
  info "Picking random template..."

  if [[ $DRY_RUN == true ]]; then
    SELECTED_TEMPLATE="$TEMPLATE_DIR/template-1"
    TEMPLATE_NAME="template-1"
    info "Using: $TEMPLATE_NAME (dry-run)"
    return 0
  fi

  local -a candidates=()
  local dir
  while IFS= read -r -d '' dir; do
    candidates+=("$dir")
  done < <(find "$TEMPLATE_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -print0)

  (( ${#candidates[@]} > 0 )) || die "No templates found in $TEMPLATE_DIR"

  SELECTED_TEMPLATE=${candidates[RANDOM % ${#candidates[@]}]}
  TEMPLATE_NAME=${SELECTED_TEMPLATE##*/}
  info "Using: $TEMPLATE_NAME"
}

detect_web_user() {
  local user=""
  # Prefer the user nginx is actually configured to run as.
  user=$(nginx -T 2>/dev/null | awk '$1 == "user" { gsub(/;/, "", $2); print $2; exit }') || true
  if [[ -n $user ]] && id "$user" >/dev/null 2>&1; then
    echo "$user"
    return 0
  fi
  for user in www-data nginx apache; do
    if id "$user" >/dev/null 2>&1; then
      echo "$user"
      return 0
    fi
  done
  return 1
}

deploy_template() {
  info "Deploying $TEMPLATE_NAME to $WEB_ROOT..."

  if [[ -d $WEB_ROOT && -n $(ls -A "$WEB_ROOT" 2>/dev/null) ]]; then
    local backup
    backup="${WEB_ROOT}.backup.$(date +%s)"
    run "Back up existing web root to $backup" mv "$WEB_ROOT" "$backup"
  fi

  run "Create web root" mkdir -p "$WEB_ROOT"
  run "Copy template files" cp -a "$SELECTED_TEMPLATE/." "$WEB_ROOT/"

  local web_user
  if web_user=$(detect_web_user); then
    run "Set owner to $web_user" chown -R "$web_user:$web_user" "$WEB_ROOT"
  else
    warn "No web user (www-data/nginx/apache) found; leaving ownership as is"
  fi
  run "Set permissions" chmod -R 'u=rwX,go=rX' "$WEB_ROOT"

  info "Deployed: $TEMPLATE_NAME"
}

# ─── nginx ──────────────────────────────────────────────────────────────────

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

restart_nginx() {
  info "Restarting nginx..."
  run "Test nginx config" nginx -t

  if has_systemd; then
    run "Enable nginx" systemctl enable nginx || warn "Could not enable nginx at boot"
    run "Restart nginx" systemctl restart nginx
  elif command -v rc-service >/dev/null 2>&1; then
    run "Enable nginx" rc-update add nginx default || warn "Could not enable nginx at boot"
    run "Restart nginx" rc-service nginx restart
  else
    run "Restart nginx" service nginx restart
  fi

  if [[ $DRY_RUN == true ]]; then
    return 0
  fi

  local attempt
  for attempt in 1 2 3 4 5; do
    if curl -fsS --max-time 5 -o /dev/null http://127.0.0.1/ 2>/dev/null; then
      info "Nginx health check passed"
      return 0
    fi
    sleep 1
  done
  warn "Nginx health check failed (is port 80 used by another service?)"
}

nginx_state() {
  local state=""
  if has_systemd; then
    state=$(systemctl is-active nginx 2>/dev/null || true)
  elif pgrep -x nginx >/dev/null 2>&1; then
    state="running"
  fi
  echo "${state:-unknown}"
}

# ─── CLI ────────────────────────────────────────────────────────────────────

show_help() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION - VPS setup for direct configs

Usage:
  bash <(curl -fsSL $RAW_URL)
  $SCRIPT_NAME [-h|--help] [-v|--version]

Environment variables:
  TEMPLATE_REPO     GitHub repo with templates   (default: $DEFAULT_TEMPLATE_REPO)
  TEMPLATE_BRANCH   HEAD, branch, tag or commit  (default: $DEFAULT_TEMPLATE_BRANCH = repo default branch)
  TEMPLATE_SHA256   Expected SHA256 of the template zip (optional)
  WEB_ROOT          Web root directory           (default: $DEFAULT_WEB_ROOT)
  WORK_DIR          Parent dir for temp files    (default: \$TMPDIR or /tmp)
  LOG_FILE          Log file path                (default: $DEFAULT_LOG_FILE)
  LOG_LEVEL         0=DEBUG 1=INFO 2=WARN 3=ERROR (default: 1)
  LOG_JSON          JSON structured log file     (default: false)
  SKIP_PACKAGES     Skip package install         (default: false)
  SKIP_TEMPLATE     Skip template deploy         (default: false)
  SKIP_ROOT_CHECK   Skip root check              (default: false)
  SKIP_OS_CHECK     Skip OS check                (default: false)
  SKIP_SERVER_INFO  Skip IP/country/ISP lookup   (default: false)
  DRY_RUN           Print actions, change nothing (default: false)

Examples:
  DRY_RUN=true bash <(curl -fsSL $RAW_URL)
  SKIP_TEMPLATE=true bash <(curl -fsSL $RAW_URL)
  TEMPLATE_REPO="me/myrepo" bash <(curl -fsSL $RAW_URL)
  LOG_JSON=true LOG_LEVEL=0 bash <(curl -fsSL $RAW_URL)
EOF
}

parse_args() {
  case ${1:-} in
    "") ;;
    -h|--help)    show_help; exit 0 ;;
    -v|--version) echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
    *)            printf 'Unknown option: %s\n\n' "$1" >&2; show_help >&2; exit 2 ;;
  esac
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  validate_config
  init_logging
  trap cleanup EXIT

  info "=== $SCRIPT_NAME v$SCRIPT_VERSION ==="
  info "Repo: $TEMPLATE_REPO | Branch: $TEMPLATE_BRANCH | Root: $WEB_ROOT"
  if [[ $DRY_RUN == true ]]; then
    warn "DRY RUN - no changes will be made"
  fi

  check_root
  check_os
  install_packages
  get_server_info

  if [[ $SKIP_TEMPLATE == true ]]; then
    info "Skipping template (SKIP_TEMPLATE=true)"
  else
    download_template
    cleanup_template
    select_random_template
    deploy_template
  fi

  restart_nginx

  info "=== Done ==="
  info "IP: $SERVER_IP | Country: $SERVER_COUNTRY | ISP: $SERVER_ISP"
  if [[ $SKIP_TEMPLATE != true ]]; then
    info "Template: $TEMPLATE_NAME"
  fi
  info "Web: $WEB_ROOT | Nginx: $(nginx_state)"
}

main "$@"
