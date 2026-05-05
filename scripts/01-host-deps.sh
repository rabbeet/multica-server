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
    log_error "docker compose plugin not found — install via apt: docker-compose-plugin"
    exit 1
fi

log_ok "docker $(docker --version | awk '{print $3}' | tr -d ',') + compose $(docker compose version --short) present"

# ---- Verify host services we need to coexist with ----------------------------
for svc in postgresql redis-server containerd; do
    if systemctl is-active "$svc" >/dev/null 2>&1; then
        log_ok "Host service '$svc' is active (will reuse)"
    else
        log_warn "Host service '$svc' is NOT active — may need attention"
    fi
done

log_ok "01-host-deps complete"
