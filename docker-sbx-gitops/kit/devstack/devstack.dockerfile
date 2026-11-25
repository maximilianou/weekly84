# =============================================================================
# kit/devstack/devstack.dockerfile -- devstack workload image
#
# Companion recipe of devstack.yaml (same basename, same directory): the
# sandbox-kit frontend loads it after parsing the YAML descriptor.
# IMPORTANT: this is an ORDINARY Dockerfile. Do NOT put a
# '# syntax=docker/sandbox-kit:3' directive here -- that directive belongs
# ONLY on line 1 of devstack.yaml. If the recipe names the kit frontend, the
# build fails with: "content recipe ... names the kit frontend in its syntax
# directive; the recipe is an ordinary Dockerfile".
#
# Base: shell-docker-image = shell sandbox WITH Docker Engine inside, so the
# sandbox itself can run the dev Postgres + Adminer containers.
# Docs: https://docs.docker.com/ai/sandboxes/customize/author/base-images
# =============================================================================

FROM docker.io/sbx/shell-docker-image:latest

USER root

# Tooling: curl/gnupg (installers), jq (scripts), postgresql-client (psql for
# the agent), procps (pkill/pgrep in the bootstrap script).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg jq postgresql-client procps \
 && rm -rf /var/lib/apt/lists/*

# Node 22 -- pi requires Node >= 22.19.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# pi.dev coding agent + openspec (spec-driven development CLI) -- global, root
# installs them under /usr/local/bin so the `agent` user can execute them.
RUN npm install -g @earendil-works/pi-coding-agent @fission-ai/openspec \
 && npm cache clean --force

# herdr terminal multiplexer (agents drive it via its CLI and socket API).
RUN curl -fsSL https://herdr.dev/install.sh | sh

# -- Repo-provided files (AGENTS.md, env loader, pi model template, bootstrap) -
COPY --chown=agent:agent files/ /home/agent/

RUN chmod +x /home/agent/bootstrap/*.sh \
 && mkdir -p /home/agent/.pi/agent /home/agent/workspaces/logs \
 && echo '[ -f /home/agent/.devstack_env ] && . /home/agent/.devstack_env' \
      >> /home/agent/.bashrc \
 && chown -R agent:agent /home/agent

# BASH_ENV makes the devstack exports available to non-interactive
# `bash -c` calls (what `sbx exec` runs); ~/.bashrc covers interactive shells.
ENV BASH_ENV=/home/agent/.devstack_env

USER agent
ENTRYPOINT ["bash"]
CMD []
