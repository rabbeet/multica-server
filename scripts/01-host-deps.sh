#!/usr/bin/env bash
# 01-host-deps.sh — install missing host packages.
#
# Per DEPLOYMENT_CONTEXT.md, the Contabo host already has docker, containerd,
# fail2ban, postgres-16, redis. We only install the gaps.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root

# ---- apt packages we need ----------------------------------------------------
APT_PKGS=(
    curl
    jq
    git
    mosh
    tmux
    direnv
    ca-certificates
    gnupg
    rsync
    sudo
    netcat-openbsd
)

log_info "Updating apt index..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq

# Filter to packages not already installed
to_install=()
for pkg in "${APT_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        to_install+=("$pkg")
    fi
done

if [[ ${#to_install[@]} -eq 0 ]]; then
    log_skip "All apt packages already installed"
else
    log_info "Installing: ${to_install[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${to_install[@]}"
    log_ok "Installed ${#to_install[@]} apt packages"
fi

# ---- yq (mikefarah/yq, NOT python3-yq from apt) ------------------------------
# We need v4+. Apt's `yq` is python-based and incompatible.
YQ_VERSION="v4.44.3"
YQ_BIN="/usr/local/bin/yq"

if [[ -x "$YQ_BIN" ]] && "$YQ_BIN" --version 2>/dev/null | grep -q 'v4\.'; then
    log_skip "yq already installed: $($YQ_BIN --version)"
else
    log_info "Installing yq $YQ_VERSION..."
    arch=$(uname -m)
    case "$arch" in
        x86_64)  yq_arch="amd64" ;;
        aarch64) yq_arch="arm64" ;;
        *) log_error "Unsupported arch for yq: $arch"; exit 1 ;;
    esac
    curl -sSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${yq_arch}" \
        -o "$YQ_BIN"
    chmod +x "$YQ_BIN"
    log_ok "Installed yq: $($YQ_BIN --version)"
fi

# ---- Go (golang.org/dl, NOT apt's outdated 1.21) -----------------------------
# Required for agents working on rabbeet/multica (Go backend) and
# rabbeet/multica-server (this repo). Without this, `make setup` in those
# worktrees dies with `go: command not found` and the agent has to hand-roll
# Go into ~/.local. Pinned because the multica `go.mod` requires >= 1.26.
GO_VERSION="1.26.0"

install_go() {
    local go_dir="/usr/local/go"
    if [[ -x "$go_dir/bin/go" ]] && "$go_dir/bin/go" version 2>/dev/null | grep -q "go${GO_VERSION}"; then
        log_skip "go ${GO_VERSION} already installed"
        return 0
    fi
    log_info "Installing go ${GO_VERSION}..."
    local arch go_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  go_arch="amd64" ;;
        aarch64) go_arch="arm64" ;;
        *) log_error "Unsupported arch for go: $arch"; return 1 ;;
    esac
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN
    # `-f` makes curl exit non-zero on HTTP 4xx/5xx instead of silently
    # writing an HTML error body into go.tgz (which would then explode in
    # tar with a cryptic gzip error).
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz" -o "$tmp/go.tgz"
    # Atomic install: extract to a staging dir on the same filesystem as
    # $go_dir, then `mv` swap. If tar fails mid-extract, the live Go
    # tree at $go_dir is untouched and any concurrent `make setup` in an
    # agent worktree keeps working.
    local stage
    stage=$(mktemp -d -p /usr/local .go-staging-XXXXXX)
    tar -C "$stage" -xzf "$tmp/go.tgz"
    "$stage/go/bin/go" version >/dev/null
    rm -rf "${go_dir}.old"
    [[ -d "$go_dir" ]] && mv "$go_dir" "${go_dir}.old"
    mv "$stage/go" "$go_dir"
    rm -rf "$stage" "${go_dir}.old"
    ln -sf "$go_dir/bin/go" /usr/local/bin/go
    ln -sf "$go_dir/bin/gofmt" /usr/local/bin/gofmt
    log_ok "Installed: $($go_dir/bin/go version)"
}
install_go

# ---- sqlc (pinned — full regen with different version produces drift) --------
# Required for `make generate` in rabbeet/multica. Version is pinned because
# v1.30.0 and v1.31.1 emit subtly different cascade-related columns and
# mixing causes diff churn (see PUL-102 / PUL-163 context).
SQLC_VERSION="1.31.1"

install_sqlc() {
    local sqlc_bin="/usr/local/bin/sqlc"
    if [[ -x "$sqlc_bin" ]] && "$sqlc_bin" version 2>/dev/null | grep -q "v${SQLC_VERSION}"; then
        log_skip "sqlc v${SQLC_VERSION} already installed"
        return 0
    fi
    log_info "Installing sqlc v${SQLC_VERSION}..."
    local arch sqlc_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  sqlc_arch="amd64" ;;
        aarch64) sqlc_arch="arm64" ;;
        *) log_error "Unsupported arch for sqlc: $arch"; return 1 ;;
    esac
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN
    curl -fsSL "https://github.com/sqlc-dev/sqlc/releases/download/v${SQLC_VERSION}/sqlc_${SQLC_VERSION}_linux_${sqlc_arch}.tar.gz" -o "$tmp/sqlc.tgz"
    tar -C "$tmp" -xzf "$tmp/sqlc.tgz"
    # `install -m 0755` is atomic (open+chmod+rename), so no staging dir
    # needed here — sqlc is a single binary, unlike Go's full tree.
    install -m 0755 "$tmp/sqlc" "$sqlc_bin"
    log_ok "Installed: $($sqlc_bin version)"
}
install_sqlc

# ---- Tailscale ---------------------------------------------------------------
if command -v tailscale >/dev/null 2>&1; then
    log_skip "Tailscale already installed: $(tailscale version | head -1)"
else
    log_info "Installing Tailscale via official script..."
    curl -fsSL https://tailscale.com/install.sh | sh
    log_ok "Tailscale installed: $(tailscale version | head -1)"
fi

# ---- Verify Docker (must be installed; we don't install — it's already there) -
if ! command -v docker >/dev/null 2>&1; then
    log_error "docker not found — this script assumes Docker is already installed (per DEPLOYMENT_CONTEXT.md)"
    log_error "If Docker is genuinely missing, install via: curl -fsSL https://get.docker.com | sh"
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    log_info "docker compose plugin not found — installing..."

    # Try apt first (works if Docker's official apt repo is configured)
    if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin
    else
        # Fallback: install Docker's official apt repo, then the plugin
        log_info "Docker apt repo not configured — adding it..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        codename=$(. /etc/os-release; echo "$VERSION_CODENAME")
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_error "docker compose still not working after install attempt"
        exit 1
    fi
    log_ok "docker compose plugin installed"
fi

log_ok "docker $(docker --version | awk '{print $3}' | tr -d ',') + compose $(docker compose version --short) present"

# ---- PHP 8.4 + composer (for agent pre-PR static checks; matches CI) --------
# The pre-pr-checks hook (agent/hooks/pre-pr-checks.sh) runs pint + npm scripts
# inside agent worktrees before `gh pr create` to catch lint/format/types fails
# locally. Without these, agents push PRs that immediately fail CI.
PHP_VERSION="8.4"
PHP_PKGS=(
    "php${PHP_VERSION}-cli"
    "php${PHP_VERSION}-mbstring"
    "php${PHP_VERSION}-xml"
    "php${PHP_VERSION}-curl"
    "php${PHP_VERSION}-zip"
    "php${PHP_VERSION}-bcmath"
    "php${PHP_VERSION}-intl"
    "php${PHP_VERSION}-sqlite3"
    "php${PHP_VERSION}-gd"
)

if command -v php >/dev/null 2>&1 && php -v 2>/dev/null | grep -q "PHP ${PHP_VERSION}"; then
    log_skip "PHP ${PHP_VERSION} already installed: $(php -v | head -1)"
else
    log_info "Installing PHP ${PHP_VERSION} from ondrej/php PPA..."
    if ! grep -rq "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common
        add-apt-repository -y ppa:ondrej/php
        apt-get update -qq
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${PHP_PKGS[@]}"
    log_ok "PHP installed: $(php -v | head -1)"
fi

if command -v composer >/dev/null 2>&1; then
    log_skip "composer already installed: $(composer --version | head -1)"
else
    log_info "Installing composer to /usr/local/bin..."
    EXPECTED_HASH=$(curl -sSL https://composer.github.io/installer.sig)
    php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
    ACTUAL_HASH=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")
    if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
        log_error "composer installer checksum mismatch — aborting"
        rm -f /tmp/composer-setup.php
        exit 1
    fi
    php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
    log_ok "composer installed: $(composer --version | head -1)"
fi

# ---- Node.js 20 LTS + npm (matches CI default runner Node) ------------------
NODE_MAJOR=20
if command -v node >/dev/null 2>&1 && node -v | grep -q "^v${NODE_MAJOR}\."; then
    log_skip "Node ${NODE_MAJOR}.x already installed: $(node -v)"
else
    log_info "Installing Node.js ${NODE_MAJOR}.x from NodeSource..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor --batch --yes -o /etc/apt/keyrings/nodesource.gpg
    chmod a+r /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
    log_ok "Node installed: $(node -v), npm $(npm -v)"
fi

# ---- pnpm (system-wide via npm -g, NOT corepack) ----------------------------
# Required by `make setup` in rabbeet/multica (Vue/React frontend). Installed
# via `npm install -g` so the binary lives in /usr/bin (system-wide) instead
# of corepack's per-user cache under ~/.cache/node/corepack — the daemon
# spawns agents under whichever user, and per-user shims would defer the
# download to first-invocation and could miss between agent users.
PNPM_VERSION="10.28.2"

install_pnpm() {
    if command -v pnpm >/dev/null 2>&1 && [[ "$(pnpm --version 2>/dev/null)" == "$PNPM_VERSION" ]]; then
        log_skip "pnpm ${PNPM_VERSION} already installed: $(command -v pnpm)"
        return 0
    fi
    log_info "Installing pnpm ${PNPM_VERSION} via npm -g..."
    npm install -g --silent "pnpm@${PNPM_VERSION}"
    log_ok "Installed: $(command -v pnpm) ($(pnpm --version))"
}
install_pnpm

# ---- Verify host services we need to coexist with ----------------------------
for svc in postgresql redis-server containerd; do
    if systemctl is-active "$svc" >/dev/null 2>&1; then
        log_ok "Host service '$svc' is active (will reuse)"
    else
        log_warn "Host service '$svc' is NOT active — may need attention"
    fi
done

log_ok "01-host-deps complete"
