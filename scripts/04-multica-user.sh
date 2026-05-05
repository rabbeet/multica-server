#!/usr/bin/env bash
# 04-multica-user.sh — create Linux user 'multica' with dynamic UID.
#
# Picks free UID in 1100-1199 to avoid collision with existing 'claude' user
# (happy CLI owner) and other system users.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

USERNAME="${MULTICA_USER:-multica}"

# ---- Idempotent ---------------------------------------------------------------
if id -u "$USERNAME" >/dev/null 2>&1; then
    existing_uid=$(id -u "$USERNAME")
    log_skip "User '$USERNAME' already exists (UID=$existing_uid)"
else
    UID_MIN=1100
    UID_MAX=1199
    new_uid=$(pick_free_uid $UID_MIN $UID_MAX)
    log_info "Creating user '$USERNAME' (UID=$new_uid)..."
    useradd -m -u "$new_uid" -s /bin/bash "$USERNAME"
    log_ok "Created user '$USERNAME' UID=$new_uid"
fi

# ---- Add to docker group so user can run docker ps without sudo --------------
if getent group docker >/dev/null && ! id -nG "$USERNAME" | grep -qw docker; then
    usermod -aG docker "$USERNAME"
    log_ok "Added '$USERNAME' to docker group"
fi

# ---- Set up ~/.ssh for tailscale-ssh (or fallback ssh) -----------------------
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
mkdir -p "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chown -R "$USERNAME":"$USERNAME" "$USER_HOME/.ssh"

# ---- Create /opt/multica-server symlink for the repo -------------------------
# (Repo lives where root cloned it; we expose a stable path for the user.)
REPO_LIVE="$(repo_root)"
if [[ ! -e "$USER_HOME/multica-server" ]]; then
    ln -s "$REPO_LIVE" "$USER_HOME/multica-server"
    chown -h "$USERNAME":"$USERNAME" "$USER_HOME/multica-server"
    log_ok "Symlinked $USER_HOME/multica-server -> $REPO_LIVE"
fi

# ---- /srv/plans-multica — owned by multica ----------------------------------
PLANS_DIR=/srv/plans-multica
if [[ ! -d "$PLANS_DIR" ]]; then
    mkdir -p "$PLANS_DIR"
    chown "$USERNAME":"$USERNAME" "$PLANS_DIR"
    log_ok "Created $PLANS_DIR (owned by $USERNAME)"
else
    log_skip "$PLANS_DIR already exists"
fi

# ---- Clone plans-репо if not yet cloned --------------------------------------
require_vars BRAINSTORM_PAT GITHUB_USER PLANS_REPO_HTTPS

if [[ -d "$PLANS_DIR/.git" ]]; then
    log_skip "$PLANS_DIR already cloned"
else
    # Construct authenticated HTTPS URL — token never lands in git config because
    # we use a credential helper that reads from the .env on every operation.
    auth_url="${PLANS_REPO_HTTPS/https:\/\//https://${GITHUB_USER}:${BRAINSTORM_PAT}@}"
    log_info "Cloning plans repo into $PLANS_DIR..."
    sudo -u "$USERNAME" git clone "$auth_url" "$PLANS_DIR"
    # Strip credentials from saved remote (they'll be re-injected via credential helper)
    sudo -u "$USERNAME" git -C "$PLANS_DIR" remote set-url origin "$PLANS_REPO_HTTPS"
    log_ok "Cloned plans repo"
fi

# ---- Configure git credential helper for plans-репо --------------------------
# Use a file-based store so PAT lives only at /home/multica/.git-credentials,
# not embedded in remote URL.
GIT_CRED_FILE="$USER_HOME/.git-credentials"
GIT_CRED_LINE="https://${GITHUB_USER}:${BRAINSTORM_PAT}@github.com"

if [[ -f "$GIT_CRED_FILE" ]] && grep -qF "$GIT_CRED_LINE" "$GIT_CRED_FILE"; then
    log_skip "git credential helper already configured"
else
    echo "$GIT_CRED_LINE" > "$GIT_CRED_FILE"
    chown "$USERNAME":"$USERNAME" "$GIT_CRED_FILE"
    chmod 600 "$GIT_CRED_FILE"
    sudo -u "$USERNAME" git config --global credential.helper "store --file=$GIT_CRED_FILE"
    sudo -u "$USERNAME" git config --global user.name "${GITHUB_USER}"
    sudo -u "$USERNAME" git config --global user.email "${GITHUB_USER}@users.noreply.github.com"
    log_ok "git credential helper + user.name configured"
fi

log_ok "04-multica-user complete"
