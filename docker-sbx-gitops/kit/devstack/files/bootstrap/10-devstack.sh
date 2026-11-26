#!/usr/bin/env bash
# =============================================================================
# /home/agent/bootstrap/10-devstack.sh -- idempotent in-sandbox bootstrap.
#
# Wires every component together:
#   pg-dev -- $SBX_NET_NAME -- adminer-dev
#     ^                            (containers inside the sandbox)
#     +-- 127.0.0.1:$PG_PORT -- api (node/tsx, :$API_PORT) -- web (vite, :$WEB_PORT)
#   pi -> host Ollama ($AI_OLLAMA_URL)
#
# Safe to re-run (used by `./sbx.sh up` and after reboots).
# =============================================================================
set -euo pipefail

. /home/agent/.devstack_env   # /etc/sandbox-persistent.sh + fallbacks + exports

# Logs live in the image dir (always writable, stable path for ./sbx.sh logs);
# the APP root is discovered in section 6 because the workspace mount may
# land at the host-path mirror instead of /home/agent/workspaces.
LOGDIR="/home/agent/workspaces/logs"; mkdir -p "$LOGDIR"
TAG="${SBX_NAME:-devstack}"
ok()   { printf '\033[1;32m[%s]\033[0m %s\n' "$TAG" "$*"; }
step() { printf '\033[1;36m[%s]\033[0m %s\n' "$TAG" "$*"; }
fail() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "$TAG" "$*" >&2; exit 1; }

running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

# -- 1. Docker daemon (shell-docker-image starts it at sandbox boot) ----------
step "waiting for the sandbox docker daemon..."
for _ in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  [ "${_:-0}" = "30" ] && fail "docker daemon not reachable inside the sandbox"
  sleep 1
done
ok "docker daemon ready"

# -- 2. Internal network + persistent volume ----------------------------------
docker network create "$SBX_NET_NAME" >/dev/null 2>&1 || true
docker volume create "$PGDATA_VOLUME" >/dev/null 2>&1 || true

# -- 3. PostgreSQL (development) ----------------------------------------------
if running pg-dev; then
  step "pg-dev already running"
else
  step "starting pg-dev ($POSTGRES_IMAGE)..."
  docker rm -f pg-dev >/dev/null 2>&1 || true
  docker run -d --name pg-dev --restart unless-stopped \
    --network "$SBX_NET_NAME" \
    -p 127.0.0.1:"$PG_PORT":5432 \
    -v "$PGDATA_VOLUME":/var/lib/postgresql/data \
    -e POSTGRES_USER -e POSTGRES_PASSWORD -e POSTGRES_DB \
    "$POSTGRES_IMAGE" >/dev/null
fi

# -- 4. PostgreSQL admin (Adminer) --------------------------------------------
if running adminer-dev; then
  step "adminer-dev already running"
else
  step "starting adminer-dev ($ADMINER_IMAGE)..."
  docker rm -f adminer-dev >/dev/null 2>&1 || true
  docker run -d --name adminer-dev --restart unless-stopped \
    --network "$SBX_NET_NAME" \
    -p 127.0.0.1:"$ADMINER_PORT":8080 \
    -e ADMINER_DEFAULT_SERVER \
    "$ADMINER_IMAGE" >/dev/null
fi

# -- 5. pi <-> local AI on the host (models.json) -------------------------------
step "writing pi provider config ($AI_PROVIDER)..."
case "$AI_PROVIDER" in
  model-runner) _base_url="$AI_MODEL_RUNNER_URL" ;;
  *)            _base_url="${AI_OLLAMA_URL%/}/v1" ;;
esac
mkdir -p /home/agent/.pi/agent
sed -e "s|__AI_BASE_URL__|$_base_url|g" \
    -e "s|__AI_MODEL__|$AI_OLLAMA_MODEL|g" \
    /home/agent/pi-models.template.json > /home/agent/.pi/agent/models.json
ok "pi -> $_base_url (model: $AI_OLLAMA_MODEL)"

# -- 5b. git identity + fine-grained GitHub credentials ------------------------
# GITHUB_TOKEN is a fine-grained PAT scoped to ONLY $GITHUB_OWNER/$GITHUB_REPO
# (scope and push permission verified by ./setup.sh). The credential helper
# reads the token from the environment at push time -- this script never
# writes the token to disk.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  step "configuring git for $GITHUB_OWNER/$GITHUB_REPO..."
  git config --global user.name  "$GIT_USER_NAME"
  git config --global user.email "$GIT_USER_EMAIL"
  git config --global init.defaultBranch main
  git config --global credential.helper \
    '!f() { printf "username=oauth2\npassword=%s\n" "$GITHUB_TOKEN"; }; f'
  git config --global --add safe.directory "$DEVSTACK_ROOT"
  git config --global --add safe.directory "$DEVSTACK_ROOT/api"
  git config --global --add safe.directory "$DEVSTACK_ROOT/web"
  ok "git ready -- pushes go to https://github.com/$GITHUB_OWNER/$GITHUB_REPO"
else
  step "GITHUB_TOKEN not set -- git credentials not configured"
fi

# -- 6. Workspaces: locate the app, deps, env files, dev servers --------------
# sbx mounts the env file's `workspace:` following the DECLARATION; the
# in-sandbox path can be the host-path mirror instead of /home/agent/workspaces.
# Resolve the real app root (the dir containing api/ and web/) on every run.
if [ ! -f "$DEVSTACK_ROOT/api/package.json" ]; then
  step "api/ not under $DEVSTACK_ROOT -- locating the mounted workspace..."
  for _cand in "${SBX_WORKSPACE_ROOT:-}" /home/agent/workspaces /workspace \
               /home/agent/workspace; do
    if [ -n "$_cand" ] && [ -f "$_cand/api/package.json" ]; then
      DEVSTACK_ROOT="$_cand"
      break
    fi
  done
  if [ ! -f "$DEVSTACK_ROOT/api/package.json" ]; then
    # `|| true`: find exits 1 when a start dir is missing and set -e would
    # kill the script; an empty result is handled below.
    _found="$(find /home /workspace /mnt /srv \
        \( -type d -name node_modules -o -type d -name .git \) -prune -o \
        -type f -path '*/api/package.json' -print 2>/dev/null | head -n 1 || true)"
    if [ -n "$_found" ]; then
      DEVSTACK_ROOT="$(dirname "$(dirname "$_found")")"
    fi
  fi
fi
if [ -f "$DEVSTACK_ROOT/api/package.json" ] && [ -f "$DEVSTACK_ROOT/web/package.json" ]; then
  printf '%s' "$DEVSTACK_ROOT" > /home/agent/.devstack_root 2>/dev/null || true
  ok "app workspace: $DEVSTACK_ROOT (api + web)"
else
  fail "cannot find the app workspaces (api/, web/) inside the sandbox.
    Inspect:  ./sbx.sh exec 'ls -la /home/agent /workspace 2>/dev/null'
              ./sbx.sh exec 'find /home /workspace -maxdepth 8 -name package.json -path *api*'
    Fix: sbxenv.yaml 'workspace:' must point at the directory CONTAINING api/
    and web/ (paths resolve from the env file's own directory), then
    ./sbx.sh rm && ./sbx.sh up. If the mount lands elsewhere by design, pin
    SBX_WORKSPACE_ROOT=/that/path in etc.env."
fi

write_api_env() {
  cat > "$DEVSTACK_ROOT/api/.env" <<EOF
NODE_ENV=$NODE_ENV
API_PORT=$API_PORT
DATABASE_URL=$DATABASE_URL
DATABASE_URL_INTERNAL=$DATABASE_URL_INTERNAL
VITE_API_BASE=$VITE_API_BASE
EOF
}
write_web_env() {
  cat > "$DEVSTACK_ROOT/web/.env" <<EOF
WEB_PORT=$WEB_PORT
API_PORT=$API_PORT
API_HOST=127.0.0.1
VITE_API_BASE=$VITE_API_BASE
EOF
}

# Registry pre-check FIRST: it distinguishes an egress problem (policy, proxy,
# DNS) from an npm problem. registry.npmjs.org IS in the kit allow-list, so a
# curl failure here means the sandbox outbound path, not npm itself.
if ! curl -fsS -m 15 https://registry.npmjs.org/express/latest \
       > "$LOGDIR/npm-registry-check.json" 2>&1; then
  fail "registry.npmjs.org unreachable from the sandbox (curl).
    The kit allow-list includes it, so this is an egress problem: check
    'sbx policy ls', the TUI network panel, and DNS inside the sandbox
    (getent hosts registry.npmjs.org). Log: workspaces/logs/npm-registry-check.json"
fi
ok "registry.npmjs.org reachable"

for _app in api web; do
  if [ -d "$DEVSTACK_ROOT/$_app/node_modules" ]; then
    step "checking $_app dependencies (npm install is idempotent)..."
  else
    step "installing $_app dependencies..."
  fi
  # ALWAYS run npm install: a previous FAILED install can leave a partial
  # node_modules behind, and npm install is a no-op when the tree is complete.
  (cd "$DEVSTACK_ROOT/$_app" && \
     npm install --no-audit --no-fund --fetch-retries=5) \
    > "$LOGDIR/npm-$_app.log" 2>&1 || {
    echo "[$TAG] FAIL: npm install failed for $_app -- workspaces/logs/npm-$_app.log, last lines:" >&2
    tail -n 30 "$LOGDIR/npm-$_app.log" >&2 || true
    exit 1
  }
  ok "$_app dependencies ready"
done

write_api_env
write_web_env

step "starting dev servers..."
pkill -f "tsx watch src/index.ts" >/dev/null 2>&1 || true
( cd "$DEVSTACK_ROOT/api" && nohup npm run dev > "$LOGDIR/api.log" 2>&1 & )
pkill -f "vite" >/dev/null 2>&1 || true
( cd "$DEVSTACK_ROOT/web" && nohup npm run dev > "$LOGDIR/web.log" 2>&1 & )

# Existing containers may still be attached to an older net name (project
# renamed); connect them to the current one (no-op when already attached).
docker network connect "$SBX_NET_NAME" pg-dev >/dev/null 2>&1 || true
docker network connect "$SBX_NET_NAME" adminer-dev >/dev/null 2>&1 || true

# -- 7. Health checks ---------------------------------------------------------
pg_status() {
  docker exec pg-dev pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    >/dev/null 2>&1 && echo "ready" || echo "starting"
}
adminer_status() {
  curl -fsS -m 2 "http://127.0.0.1:$ADMINER_PORT/" >/dev/null 2>&1 && echo "ready" || echo "starting"
}
web_status() {
  curl -fsS -m 2 "http://127.0.0.1:$WEB_PORT/" >/dev/null 2>&1 && echo "ready" || echo "starting"
}
api_status() {
  curl -fsS -m 2 "http://127.0.0.1:$API_PORT/api/health" >/dev/null 2>&1 && echo "ready" || echo "starting"
}

step "waiting for services..."
for _ in $(seq 1 30); do
  [ "$(api_status)" = "ready" ] && [ "$(pg_status)" = "ready" ] && break
  sleep 1
done

# -- 8. Summary ---------------------------------------------------------------
printf '\n'
printf '\033[1m%s components (inside the sandbox)\033[0m\n' "$TAG"
printf '  postgres  : %-8s pg-dev           127.0.0.1:%s  (db: %s)\n' "$(pg_status)"     "$PG_PORT"     "$POSTGRES_DB"
printf '  admin     : %-8s adminer-dev     127.0.0.1:%s  (server: %s)\n' "$(adminer_status)" "$ADMINER_PORT" "$POSTGRES_HOST"
printf '  api       : %-8s express/tsx    127.0.0.1:%s  (log: logs/api.log)\n' "$(api_status)"     "$API_PORT"
printf '  web       : %-8s vite/react     127.0.0.1:%s  (log: logs/web.log)\n' "$(web_status)"     "$WEB_PORT"
printf '  node/npm  : %s / %s\n' "$(node -v)" "$(npm -v)"
printf '  local ai  : %-8s %s  (model: %s)\n' "$AI_PROVIDER" "$_base_url" "$AI_OLLAMA_MODEL"
printf '\n'
printf 'agent tools: pi (/model -> ollama), herdr (ctrl+b q to detach), openspec\n'
printf 're-run anytime: bash /home/agent/bootstrap/10-devstack.sh\n'

if [ "$(api_status)" != "ready" ]; then
  printf '\033[1;33m[devstack] api not ready -- last log lines:\033[0m\n' >&2
  tail -n 20 "$LOGDIR/api.log" >&2 || true
  exit 1
fi
ok "$TAG is up -- API <-> Postgres round-trip verified via /api/health"
