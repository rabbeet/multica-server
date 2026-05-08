FROM ubuntu:24.04

ARG CLAUDE_VERSION=2.1.132
ARG NODE_VERSION=20
ARG BUN_VERSION=1.3.10
ARG PHP_VERSION=8.3

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/agent

# ---------- Base toolchain ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release software-properties-common \
      git openssh-client jq yq \
      postgresql-client \
      python3 python3-pip \
      build-essential \
      tini \
      cron \
    && rm -rf /var/lib/apt/lists/*

# ---------- Node + Bun (multica-core uses TypeScript/Bun) ----------
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://bun.sh/install | BUN_VERSION="${BUN_VERSION}" bash \
    && mv /root/.bun/bin/bun /usr/local/bin/bun \
    && rm -rf /root/.bun

# ---------- PHP + extensions (Pulse stack) ----------
RUN add-apt-repository -y ppa:ondrej/php \
    && apt-get update && apt-get install -y --no-install-recommends \
      php${PHP_VERSION}-cli php${PHP_VERSION}-pgsql php${PHP_VERSION}-mbstring \
      php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-zip \
      php${PHP_VERSION}-redis php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# ---------- ClickHouse client ----------
RUN curl https://clickhouse.com/ | sh \
    && mv clickhouse /usr/local/bin/ \
    && /usr/local/bin/clickhouse client --version

# ---------- GitHub CLI ----------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ---------- Claude Code CLI ----------
# Pinned version to avoid CLAUDE_CONFIG_DIR semantics drift (see design Section 10).
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION} \
    && claude --version

# ---------- Non-root user ----------
RUN useradd --create-home --uid 1200 --user-group --shell /bin/bash agent \
    && mkdir -p /home/agent/.claude /home/agent/worktrees /var/log/agent \
    && chown -R agent:agent /home/agent /var/log/agent

# ---------- Install our scripts + skills ----------
COPY --chown=agent:agent agent-spawn.sh /usr/local/bin/agent-spawn.sh
COPY --chown=agent:agent agent-healthcheck.sh /usr/local/bin/agent-healthcheck.sh
COPY --chown=agent:agent lib.sh /usr/local/bin/agent-lib.sh
COPY --chown=root:agent agent-settings.json /etc/agent-settings.json
RUN chmod 755 /usr/local/bin/agent-spawn.sh /usr/local/bin/agent-healthcheck.sh /usr/local/bin/agent-lib.sh \
    && chmod 644 /etc/agent-settings.json

# ---------- Health-check cron (every 15 min) ----------
RUN echo '*/15 * * * * agent /usr/local/bin/agent-healthcheck.sh >> /var/log/agent/healthcheck.log 2>&1' \
      > /etc/cron.d/agent-healthcheck \
    && chmod 644 /etc/cron.d/agent-healthcheck

USER agent
WORKDIR /home/agent

# tini reaps zombie processes from spawned claude sessions.
ENTRYPOINT ["/usr/bin/tini", "--"]
# Container's default command: keep alive (cron runs in foreground via crontab),
# claude processes are spawned via `docker exec ... agent-spawn.sh agent-N`.
CMD ["sleep", "infinity"]
