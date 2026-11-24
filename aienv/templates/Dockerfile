# ── aienv-base: shared image for all isolated AI development environments ──────
# Always the latest stable stack: Node LTS (lts-bookworm tracks it), latest apt
# patch level, latest GitHub CLI, latest NetBird client, latest pi and herdr.
ARG NODE_IMAGE=node:lts-bookworm
FROM ${NODE_IMAGE}

ARG UID=1000
ARG GID=1000
ENV DEBIAN_FRONTEND=noninteractive

# Start from the latest stable patch level of every package
RUN apt-get update && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && rm -rf /var/lib/apt/lists/*

# Official apt repositories: GitHub CLI + NetBird client (latest stable)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && curl -sSL https://pkgs.netbird.io/debian/public.key \
      | gpg --dearmor --output /usr/share/keyrings/netbird-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main" \
      > /etc/apt/sources.list.d/netbird.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      gh jq ripgrep fd-find vim less procps openssh-server openssh-client unzip gosu netbird \
 && rm -rf /var/lib/apt/lists/*

# pnpm via corepack (node-gyp is covered: node images ship python3, make, g++)
RUN corepack enable && corepack prepare pnpm@latest --activate

# pi coding agent + herdr multiplexer (latest stable releases)
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent
RUN curl -fsSL https://herdr.dev/install.sh | sh ; \
    if ! command -v herdr >/dev/null 2>&1; then \
      for d in /root/.local/bin "$HOME/.local/bin" /root/bin /root/.herdr/bin; do \
        if [ -x "$d/herdr" ]; then cp "$d/herdr" /usr/local/bin/herdr; break; fi; \
      done; \
    fi ; \
    chmod +x /usr/local/bin/herdr 2>/dev/null || true

# sshd: key-only access, used by herdr remote machines and mesh access
COPY sshd.conf /etc/ssh/sshd_config.d/aienv.conf
RUN ssh-keygen -A && mkdir -p /run/sshd

# Working user matching your host UID/GID (no permission issues on the bind mount)
RUN groupadd --non-unique -g "$GID" dev \
 && useradd --non-unique -m -u "$UID" -g dev -d /home/dev -s /bin/bash dev

RUN git config --system credential.helper '!gh auth git-credential' \
 && git config --system --add safe.directory /workspace \
 && git config --system init.defaultBranch main \
 && touch /home/dev/.gitconfig /home/dev/.pi/models.json /home/dev/.pi/agent/models.json \
 && mkdir -p /workspace /home/dev/.pi/agent \
 && chown -R dev:dev /workspace /home/dev

COPY entrypoint.sh /usr/local/bin/aienv-entrypoint
RUN chmod +x /usr/local/bin/aienv-entrypoint

WORKDIR /workspace
