#!/usr/bin/env bash
# Bootstrap or update daily_stock_analysis on a Debian/Ubuntu Docker host.
#
# The script is intentionally idempotent. It can install Docker/Caddy, clone or
# update the repository, import an existing .env, apply the Android HTTPS auth
# settings, bind the API to loopback, configure Caddy for unbuffered SSE, build
# the API service, and verify health endpoints.

set -Eeuo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" && -e "$SCRIPT_SOURCE" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"
else
    SCRIPT_DIR="$PWD"
fi

if [[ -z "${PROJECT_DIR:-}" ]]; then
    if git -C "$SCRIPT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
        PROJECT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
    else
        PROJECT_DIR="/opt/stock-analyzer"
    fi
fi

REPO_URL="${REPO_URL:-https://github.com/zhangfengqwer/daily_stock_analysis.git}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
DOMAIN="${DOMAIN:-}"
ENV_SOURCE="${ENV_SOURCE:-}"
SERVICE="${SERVICE:-server}"
COMPOSE_REL="docker/docker-compose.yml"
COMPOSE_FILE="$PROJECT_DIR/$COMPOSE_REL"
ENV_FILE="$PROJECT_DIR/.env"
BACKUP_DIR="${BACKUP_DIR:-$(dirname -- "$PROJECT_DIR")/stock-analyzer-backups}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
BUILD_NO_CACHE="${BUILD_NO_CACHE:-0}"
INSTALL_SYSTEM_DEPS="${INSTALL_SYSTEM_DEPS:-1}"
SETUP_CADDY="${SETUP_CADDY:-1}"
CONFIGURE_MOBILE_AUTH="${CONFIGURE_MOBILE_AUTH:-1}"
ENABLE_AGENT_MODE="${ENABLE_AGENT_MODE:-1}"
BIND_LOCAL_ONLY="${BIND_LOCAL_ONLY:-1}"
SKIP_HEALTH_CHECK="${SKIP_HEALTH_CHECK:-0}"

CADDY_BEGIN="# BEGIN daily-stock-analysis managed block"
CADDY_END="# END daily-stock-analysis managed block"
compose_stashed=0
compose_backup=""
env_backup=""
caddy_backup=""

usage() {
    cat <<'EOF'
Usage:
  sudo env DOMAIN=dsa.example.com \
    PROJECT_DIR=/opt/stock-analyzer \
    ENV_SOURCE=/home/ubuntu/stock-analyzer.env.local \
    bash install.sh

Required for a public Android deployment:
  DOMAIN                  Public HTTPS domain handled by Caddy

Environment overrides:
  PROJECT_DIR             Checkout path (repo containing this script, otherwise /opt/stock-analyzer)
  ENV_SOURCE              Existing .env to import when bootstrapping or replacing server config
  REPO_URL                Git repository URL
  REMOTE                  Git remote name (default: origin)
  BRANCH                  Deployment branch (default: main)
  SERVICE                 Docker Compose service (default: server)
  BACKUP_DIR              Config backup directory
  CADDYFILE               Caddy configuration path
  BUILD_NO_CACHE          1 performs a full Docker rebuild
  INSTALL_SYSTEM_DEPS     0 skips automatic Docker/Caddy package installation
  SETUP_CADDY             0 skips Caddy configuration and permits an empty DOMAIN
  CONFIGURE_MOBILE_AUTH   0 preserves auth/cookie/proxy .env values unchanged
  ENABLE_AGENT_MODE       0 preserves AGENT_MODE unchanged
  BIND_LOCAL_ONLY         0 preserves the Compose public port binding
  SKIP_HEALTH_CHECK       1 skips local/Caddy/public health checks

Fresh-host example after uploading the local .env:
  sudo env DOMAIN=www.example.com \
    PROJECT_DIR=/opt/stock-analyzer \
    ENV_SOURCE=/home/ubuntu/stock-analyzer.env.local \
    bash install.sh

Subsequent updates from the checkout:
  sudo env DOMAIN=www.example.com bash install.sh
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
    [[ -z "$compose_backup" ]] || printf '[install] Compose backup: %s\n' "$compose_backup" >&2
    [[ -z "$env_backup" ]] || printf '[install] Environment backup: %s\n' "$env_backup" >&2
    [[ -z "$caddy_backup" ]] || printf '[install] Caddy backup: %s\n' "$caddy_backup" >&2
    exit 1
}

on_error() {
    local code="$?"
    trap - ERR
    warn "Command failed near line ${BASH_LINENO[0]} (exit $code)"
    if [[ "$compose_stashed" == "1" ]]; then
        warn "The Compose override remains in git stash; restore it after resolving the failure"
    fi
    [[ -z "$compose_backup" ]] || warn "Compose backup remains at $compose_backup"
    [[ -z "$env_backup" ]] || warn "Environment backup remains at $env_backup"
    [[ -z "$caddy_backup" ]] || warn "Caddy backup remains at $caddy_backup"
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

require_root() {
    [[ "$EUID" -eq 0 ]] || die "System bootstrap and Caddy setup require root; rerun with sudo"
}

validate_options() {
    local key value
    for key in INSTALL_SYSTEM_DEPS SETUP_CADDY CONFIGURE_MOBILE_AUTH ENABLE_AGENT_MODE BIND_LOCAL_ONLY SKIP_HEALTH_CHECK BUILD_NO_CACHE; do
        value="${!key}"
        [[ "$value" == "0" || "$value" == "1" ]] || die "$key must be 0 or 1 (received: $value)"
    done

    if [[ "$SETUP_CADDY" == "1" ]]; then
        [[ -n "$DOMAIN" ]] || die "DOMAIN is required when SETUP_CADDY=1"
        [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "DOMAIN contains unsupported characters: $DOMAIN"
    fi
}

ensure_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true
}

timestamp() {
    date -u +%Y%m%dT%H%M%SZ
}

load_os_release() {
    [[ -r /etc/os-release ]] || die "Cannot identify Linux distribution: /etc/os-release is missing"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die "Automatic dependency installation supports Debian/Ubuntu only (detected: ${ID:-unknown})" ;;
    esac
    [[ -n "${VERSION_CODENAME:-}" || -n "${UBUNTU_CODENAME:-}" ]] \
        || die "Linux release codename is unavailable in /etc/os-release"
}

install_base_packages() {
    require_root
    load_os_release
    log "Installing base packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git gpg debian-keyring debian-archive-keyring apt-transport-https
}

install_docker() {
    require_root
    load_os_release

    local distro="$ID"
    local suite="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    local architecture
    architecture="$(dpkg --print-architecture)"

    log "Installing Docker Engine and Docker Compose v2 from the official repository"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${distro}
Suites: ${suite}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

install_caddy() {
    require_root
    log "Installing Caddy from the official stable repository"

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list

    apt-get update
    apt-get install -y caddy
}

ensure_system_dependencies() {
    if [[ "$INSTALL_SYSTEM_DEPS" == "1" ]]; then
        if ! command -v curl >/dev/null 2>&1 \
            || ! command -v git >/dev/null 2>&1 \
            || ! command -v gpg >/dev/null 2>&1; then
            install_base_packages
        fi

        if ! command -v docker >/dev/null 2>&1 \
            || ! docker compose version >/dev/null 2>&1; then
            install_base_packages
            install_docker
        fi

        if [[ "$SETUP_CADDY" == "1" ]] && ! command -v caddy >/dev/null 2>&1; then
            install_base_packages
            install_caddy
        fi
    fi

    require_command curl
    require_command git
    require_command docker
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)"

    if [[ "$SETUP_CADDY" == "1" ]]; then
        require_command caddy
        require_root
    fi
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

backup_env_once() {
    if [[ -f "$ENV_FILE" && -z "$env_backup" ]]; then
        ensure_backup_dir
        env_backup="$BACKUP_DIR/env.$(timestamp)"
        cp -a "$ENV_FILE" "$env_backup"
        chmod 600 "$env_backup" 2>/dev/null || true
        log "Backed up the environment file to $env_backup"
    fi
}

set_env_value() {
    local key="$1"
    local value="$2"
    local current=""
    local tmp

    current="$(read_env_value "$key")"
    if [[ "$current" == "$value" ]]; then
        return
    fi

    backup_env_once
    tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
    awk -F= -v target="$key" '
        /^[[:space:]]*#/ || index($0, "=") == 0 { print; next }
        $1 != target { print }
    ' "$ENV_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$ENV_FILE"
    log "Set $key"
}

set_env_default() {
    local key="$1"
    local value="$2"
    if [[ -z "$(read_env_value "$key")" ]]; then
        set_env_value "$key" "$value"
    fi
}

prepare_environment() {
    if [[ -n "$ENV_SOURCE" ]]; then
        [[ -r "$ENV_SOURCE" ]] || die "ENV_SOURCE is not readable: $ENV_SOURCE"
        local source_path target_path
        source_path="$(readlink -f "$ENV_SOURCE")"
        target_path="$(readlink -m "$ENV_FILE")"
        if [[ "$source_path" != "$target_path" ]]; then
            backup_env_once
            install -m 600 "$source_path" "$ENV_FILE"
            log "Imported environment configuration from $source_path"
        fi
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        die "No .env found. Upload your local .env and rerun with ENV_SOURCE=/path/to/uploaded.env"
    fi
    chmod 600 "$ENV_FILE" 2>/dev/null || true

    if [[ "$CONFIGURE_MOBILE_AUTH" == "1" ]]; then
        set_env_default API_PORT 8000
        set_env_default REPORT_LANGUAGE zh
        set_env_value ADMIN_AUTH_ENABLED true
        set_env_value ADMIN_SESSION_COOKIE_SAMESITE none
        set_env_value TRUST_X_FORWARDED_FOR true
        set_env_value CORS_ALLOW_ALL false
    fi
    if [[ "$ENABLE_AGENT_MODE" == "1" ]]; then
        set_env_value AGENT_MODE true
    fi

    local duplicates
    duplicates="$(awk -F= '
        !/^[[:space:]]*#/ && index($0, "=") > 0 { count[$1]++ }
        END { for (key in count) if (count[key] > 1) print key }
    ' "$ENV_FILE" | sort)"
    [[ -z "$duplicates" ]] || die "Duplicate .env keys detected: $duplicates"

    if [[ -z "$(read_env_value LITELLM_MODEL)" && -z "$(read_env_value AGENT_LITELLM_MODEL)" ]]; then
        warn "No LITELLM_MODEL or AGENT_LITELLM_MODEL is configured; Agent requests may fail"
    fi
}

backup_compose_once() {
    if [[ -z "$compose_backup" ]]; then
        ensure_backup_dir
        compose_backup="$BACKUP_DIR/docker-compose.$(timestamp).yml"
        cp -a "$COMPOSE_FILE" "$compose_backup"
        log "Backed up Docker Compose to $compose_backup"
    fi
}

update_repository() {
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
        backup_compose_once
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
}

ensure_loopback_binding() {
    [[ "$BIND_LOCAL_ONLY" == "1" ]] || return

    local public_binding='      - "${API_PORT:-8000}:${API_PORT:-8000}"'
    local loopback_binding='      - "127.0.0.1:${API_PORT:-8000}:${API_PORT:-8000}"'

    if grep -Fq -- "$loopback_binding" "$COMPOSE_FILE"; then
        log "Docker API port is already bound to 127.0.0.1"
        return
    fi
    grep -Fq -- "$public_binding" "$COMPOSE_FILE" \
        || die "Could not identify the server port mapping in $COMPOSE_FILE; refusing to expose the API"

    backup_compose_once
    sed -i "s#${public_binding}#${loopback_binding}#" "$COMPOSE_FILE"
    grep -Fq -- "$loopback_binding" "$COMPOSE_FILE" \
        || die "Failed to bind the Docker API port to 127.0.0.1"
    log "Restricted the Docker API port to 127.0.0.1"
}

backup_caddy_once() {
    if [[ -f "$CADDYFILE" && -z "$caddy_backup" ]]; then
        ensure_backup_dir
        caddy_backup="$BACKUP_DIR/Caddyfile.$(timestamp)"
        cp -a "$CADDYFILE" "$caddy_backup"
        log "Backed up Caddy configuration to $caddy_backup"
    fi
}

configure_caddy() {
    [[ "$SETUP_CADDY" == "1" ]] || return

    require_root
    mkdir -p "$(dirname -- "$CADDYFILE")"
    touch "$CADDYFILE"

    if grep -Fq "$CADDY_BEGIN" "$CADDYFILE"; then
        grep -Fq "$CADDY_END" "$CADDYFILE" \
            || die "Managed Caddy block is incomplete in $CADDYFILE; restore the backup or add $CADDY_END"
        backup_caddy_once
        local tmp
        tmp="$(mktemp "${CADDYFILE}.tmp.XXXXXX")"
        awk -v begin="$CADDY_BEGIN" -v end="$CADDY_END" '
            $0 == begin { skipping=1; next }
            $0 == end { skipping=0; next }
            !skipping { print }
        ' "$CADDYFILE" > "$tmp"
        cat "$tmp" > "$CADDYFILE"
        rm -f "$tmp"
    elif grep -Fq "$DOMAIN {" "$CADDYFILE"; then
        grep -Eq 'flush_interval[[:space:]]+-1' "$CADDYFILE" \
            || die "$DOMAIN already exists in $CADDYFILE but flush_interval -1 is missing; update that site block manually"
        log "Using the existing Caddy site block for $DOMAIN"
        caddy validate --config "$CADDYFILE"
        systemctl enable --now caddy
        systemctl reload caddy
        configure_ufw
        return
    else
        backup_caddy_once
    fi

    cat >>"$CADDYFILE" <<EOF

$CADDY_BEGIN
$DOMAIN {
    reverse_proxy 127.0.0.1:$(read_env_value API_PORT) {
        flush_interval -1
    }
}
$CADDY_END
EOF

    caddy fmt --overwrite "$CADDYFILE"
    caddy validate --config "$CADDYFILE"
    systemctl enable --now caddy
    systemctl reload caddy
    log "Configured Caddy HTTPS/SSE proxy for $DOMAIN"

    configure_ufw
}

configure_ufw() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        log "Allowed ports 80/443 in active UFW"
    fi
}

wait_for_url() {
    local label="$1"
    local url="$2"
    local resolve_args="${3:-}"
    local attempt
    local -a curl_args=(--fail --silent --show-error --location --max-time 15)

    if [[ -n "$resolve_args" ]]; then
        curl_args+=(--resolve "$resolve_args")
    fi

    for attempt in $(seq 1 24); do
        if curl "${curl_args[@]}" "$url" >/dev/null 2>&1; then
            log "$label health check passed: $url"
            return 0
        fi
        sleep 5
    done
    return 1
}

build_and_start() {
    log "Validating Docker Compose"
    docker compose -f "$COMPOSE_FILE" config --quiet

    local -a build_args=(docker compose -f "$COMPOSE_FILE" build)
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
}

run_health_checks() {
    [[ "$SKIP_HEALTH_CHECK" != "1" ]] || {
        warn "Skipping health checks"
        return
    }

    local api_port
    api_port="$(read_env_value API_PORT)"
    [[ "$api_port" =~ ^[0-9]+$ ]] || die "API_PORT must be numeric: $api_port"

    local local_url="http://127.0.0.1:${api_port}/api/v1/health"
    if ! wait_for_url "Local API" "$local_url"; then
        docker compose -f "$COMPOSE_FILE" logs --tail=200 "$SERVICE" || true
        die "Local API health check failed after 120 seconds: $local_url"
    fi

    if [[ "$BIND_LOCAL_ONLY" == "1" ]]; then
        local published
        published="$(docker compose -f "$COMPOSE_FILE" port "$SERVICE" "$api_port" 2>/dev/null || true)"
        [[ "$published" == 127.0.0.1:* ]] \
            || die "Docker published port is not loopback-only: ${published:-unknown}"
    fi

    if [[ "$SETUP_CADDY" == "1" && -n "$DOMAIN" ]]; then
        local public_url="https://${DOMAIN}/api/v1/health"
        if ! wait_for_url "Local Caddy" "$public_url" "${DOMAIN}:443:127.0.0.1"; then
            journalctl -u caddy -n 100 --no-pager || true
            die "Caddy HTTPS health check failed; verify DNS points to this server and cloud ports 80/443 are open"
        fi

        if ! curl --fail --silent --show-error --location --max-time 20 "$public_url" >/dev/null 2>&1; then
            warn "Public DNS health check failed from this host: $public_url"
            warn "The service is healthy through local Caddy; verify the cloud security group allows TCP 80/443"
        else
            log "Public health check passed: $public_url"
        fi
    fi
}

main() {
    validate_options
    ensure_system_dependencies
    update_repository
    prepare_environment
    ensure_loopback_binding
    configure_caddy
    build_and_start
    run_health_checks

    log "Deployment completed successfully"
    log "Commit: $(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
    if [[ -n "$DOMAIN" ]]; then
        log "Open: https://${DOMAIN}"
        log "Android backend address: https://${DOMAIN}"
    fi
    log "Backups: $BACKUP_DIR"
}

main
