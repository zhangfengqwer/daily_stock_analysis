#!/usr/bin/env bash
# Update or install daily_stock_analysis on a Linux Docker host.
#
# The script preserves a server-local docker/docker-compose.yml override,
# switches an existing feature-branch checkout to main, rebuilds only the API
# server, and verifies the local/public health endpoints.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"

REPO_URL="${REPO_URL:-https://github.com/zhangfengqwer/daily_stock_analysis.git}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
DOMAIN="${DOMAIN:-}"
SERVICE="${SERVICE:-server}"
COMPOSE_REL="docker/docker-compose.yml"
COMPOSE_FILE="$PROJECT_DIR/$COMPOSE_REL"
ENV_FILE="$PROJECT_DIR/.env"
BACKUP_DIR="${BACKUP_DIR:-$(dirname -- "$PROJECT_DIR")/stock-analyzer-backups}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
BUILD_NO_CACHE="${BUILD_NO_CACHE:-0}"
SKIP_ENV_CHECK="${SKIP_ENV_CHECK:-0}"
SKIP_CADDY_CHECK="${SKIP_CADDY_CHECK:-0}"
SKIP_HEALTH_CHECK="${SKIP_HEALTH_CHECK:-0}"

compose_stashed=0
compose_backup=""

usage() {
    cat <<'EOF'
Usage: bash install.sh

Environment overrides:
  PROJECT_DIR        Repository path (default: directory containing install.sh)
  REPO_URL           Git repository URL
  REMOTE             Git remote name (default: origin)
  BRANCH             Deployment branch (default: main)
  DOMAIN             Public domain for Caddy/public health checks
  SERVICE            Docker Compose service (default: server)
  BUILD_NO_CACHE     Set to 1 for a full Docker rebuild
  BACKUP_DIR         Directory for Compose override backups
  CADDYFILE          Caddy configuration path
  SKIP_ENV_CHECK     Set to 1 to skip Android authentication config warnings
  SKIP_CADDY_CHECK   Set to 1 to skip Caddy checks
  SKIP_HEALTH_CHECK  Set to 1 to skip local and public health checks

Example:
  PROJECT_DIR=/opt/stock-analyzer DOMAIN=dsa.example.com bash install.sh
EOF
}

log() {
    printf '[install] %s\n' "$*"
}

warn() {
    printf '[install] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[install] ERROR: %s\n' "$*" >&2
    if [[ -n "$compose_backup" ]]; then
        printf '[install] Compose backup: %s\n' "$compose_backup" >&2
    fi
    exit 1
}

on_error() {
    local code="$?"
    trap - ERR
    warn "Command failed near line ${BASH_LINENO[0]} (exit $code)"
    if [[ "$compose_stashed" == "1" ]]; then
        warn "The Compose override remains in git stash; restore it after resolving the failure"
    fi
    if [[ -n "$compose_backup" ]]; then
        warn "The Compose backup remains at $compose_backup"
    fi
    exit "$code"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
[[ $# -eq 0 ]] || die "Unknown argument: $1 (use --help)"
trap on_error ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

read_env_value() {
    local key="$1"
    local value
    value="$(sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1 | tr -d '\r')"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s' "$value"
}

check_mobile_env() {
    if [[ "$SKIP_ENV_CHECK" == "1" ]]; then
        warn "Skipping mobile authentication environment checks"
        return
    fi

    local auth_enabled same_site trust_proxy
    auth_enabled="$(read_env_value ADMIN_AUTH_ENABLED)"
    same_site="$(read_env_value ADMIN_SESSION_COOKIE_SAMESITE)"
    trust_proxy="$(read_env_value TRUST_X_FORWARDED_FOR)"

    [[ "${auth_enabled,,}" == "true" ]] || warn "ADMIN_AUTH_ENABLED should be true for the public mobile deployment"
    [[ "${same_site,,}" == "none" ]] || warn "ADMIN_SESSION_COOKIE_SAMESITE should be none for the Android App"
    [[ "${trust_proxy,,}" == "true" ]] || warn "TRUST_X_FORWARDED_FOR should be true behind Caddy/Nginx"
}

check_caddy() {
    if [[ "$SKIP_CADDY_CHECK" == "1" ]]; then
        warn "Skipping Caddy configuration checks"
        return
    fi
    if [[ -z "$DOMAIN" ]]; then
        warn "DOMAIN is not set; skipping Caddy domain and public health checks"
        return
    fi
    if [[ ! -r "$CADDYFILE" ]]; then
        warn "Caddyfile not readable at $CADDYFILE; verify the reverse proxy manually"
        return
    fi

    grep -Fq "$DOMAIN" "$CADDYFILE" || warn "$DOMAIN was not found in $CADDYFILE"
    grep -Eq 'flush_interval[[:space:]]+-1' "$CADDYFILE" \
        || warn "Caddy flush_interval -1 was not found; SSE may be buffered"

    if command -v caddy >/dev/null 2>&1; then
        caddy validate --config "$CADDYFILE"
    fi
}

wait_for_local_health() {
    local port="$1"
    local url="http://127.0.0.1:${port}/api/v1/health"
    local attempt

    for attempt in $(seq 1 24); do
        if curl --fail --silent --show-error --max-time 10 "$url" >/dev/null 2>&1; then
            log "Local health check passed: $url"
            return 0
        fi
        sleep 5
    done

    docker compose -f "$COMPOSE_FILE" logs --tail=200 "$SERVICE" || true
    die "Local health check failed after 120 seconds: $url"
}

require_command git
require_command docker
require_command curl

if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose v2 is required (docker compose)"
fi

if [[ ! -d "$PROJECT_DIR/.git" ]]; then
    log "Cloning $REPO_URL ($BRANCH) into $PROJECT_DIR"
    mkdir -p "$(dirname -- "$PROJECT_DIR")"
    git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$PROJECT_DIR"
fi

cd "$PROJECT_DIR"

[[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: $COMPOSE_FILE"

if ! git diff --quiet -- . ":(exclude)$COMPOSE_REL" \
    || ! git diff --cached --quiet -- . ":(exclude)$COMPOSE_REL"; then
    die "Tracked files other than $COMPOSE_REL have local changes; commit or stash them first"
fi

if ! git diff --quiet -- "$COMPOSE_REL" \
    || ! git diff --cached --quiet -- "$COMPOSE_REL"; then
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true
    compose_backup="$BACKUP_DIR/docker-compose.$(date -u +%Y%m%dT%H%M%SZ).yml"
    cp -a "$COMPOSE_FILE" "$compose_backup"
    log "Backed up the server Compose override to $compose_backup"
    git stash push -m "install.sh server compose override" -- "$COMPOSE_REL"
    compose_stashed=1
fi

log "Fetching $REMOTE and switching to $BRANCH"
git fetch --prune "$REMOTE"

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git switch "$BRANCH"
else
    git switch -c "$BRANCH" --track "$REMOTE/$BRANCH"
fi

git pull --ff-only "$REMOTE" "$BRANCH"
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "$REMOTE/$BRANCH")" ]]; then
    die "Local $BRANCH is not identical to $REMOTE/$BRANCH; refusing to deploy unpushed commits"
fi
log "Deploying commit $(git rev-parse --short HEAD)"

if [[ "$compose_stashed" == "1" ]]; then
    if ! git stash pop 'stash@{0}'; then
        die "Could not reapply the server Compose override; resolve the conflict before deploying"
    fi
    compose_stashed=0
fi

if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$PROJECT_DIR/.env.example" ]]; then
        cp "$PROJECT_DIR/.env.example" "$ENV_FILE"
        chmod 600 "$ENV_FILE" 2>/dev/null || true
        die "Created $ENV_FILE from .env.example; configure it, then rerun install.sh"
    fi
    die "Environment file not found: $ENV_FILE"
fi

check_mobile_env
check_caddy

log "Validating Docker Compose"
docker compose -f "$COMPOSE_FILE" config --quiet

build_args=(docker compose -f "$COMPOSE_FILE" build)
if [[ "$BUILD_NO_CACHE" == "1" ]]; then
    build_args+=(--no-cache)
    log "Building $SERVICE without cache; dependency installation can take several minutes"
else
    log "Building $SERVICE with Docker cache"
fi
build_args+=("$SERVICE")
"${build_args[@]}"

log "Recreating $SERVICE"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps "$SERVICE"
docker compose -f "$COMPOSE_FILE" ps

if [[ "$SKIP_HEALTH_CHECK" != "1" ]]; then
    api_port="$(read_env_value API_PORT)"
    [[ "$api_port" =~ ^[0-9]+$ ]] || api_port="8000"
    wait_for_local_health "$api_port"

    if [[ -n "$DOMAIN" ]]; then
        public_health_url="https://${DOMAIN}/api/v1/health"
        if curl --fail --silent --show-error --location --max-time 20 "$public_health_url" >/dev/null; then
            log "Public health check passed: $public_health_url"
        else
            warn "Public health check failed: $public_health_url"
            warn "Check DNS, TLS, firewall and reverse-proxy configuration"
        fi
    fi
else
    warn "Skipping health checks"
fi

log "Deployment completed"
if [[ -n "$DOMAIN" ]]; then
    log "Verify SSE with an authenticated POST to https://${DOMAIN}/api/v1/agent/chat/stream"
else
    log "Set DOMAIN on the next run to include Caddy and public health checks"
fi
