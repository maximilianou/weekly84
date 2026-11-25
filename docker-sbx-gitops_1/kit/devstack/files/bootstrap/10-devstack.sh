#!/usr/bin/env bash
# =============================================================================
# /home/agent/bootstrap/10-devstack.sh — idempotent in-sandbox bootstrap.
#
# Wires every component together:
#   pg-dev ── devnet ── adminer-dev
#     ▲                            (containers inside the sandbox)
#     └── 127.0.0.1:$PG_PORT ── api (node/tsx, :$API_PORT) ── web (vite, :$WEB_PORT)
#   pi → host Ollama ($AI_OLLAMA_URL)
#
# Safe to re-run (used by `./sbx.sh up` and after reboots).
# =============================================================================
set -euo pipefail

. /home/agent/.devstack_env   # /etc/sandbox-persistent.sh + fallbacks + exports

LOGDIR="$DEVSTACK_ROOT/logs"; mkdir -p "$LOGDIR"
ok()   { printf '\033[1;32m[devstack]\033[0m %s\n' "$*"; }
step() { printf '\033[1;36m[devstack]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[devstack] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

# ── 1. Docker daemon (shell-docker-image starts it at sandbox boot) ──────────
step "waiting for the sandbox docker daemon…"
for _ in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  [ "${_:-0}" = "30" ] && fail "docker daemon not reachable inside the sandbox"
  sleep 1
done
ok "docker daemon ready"

# ── 2. Internal network + persistent volume ──────────────────────────────────
docker network create "$SBX_NET_NAME" >/dev/null 2>&1 || true
docker volume create "$PGDATA_VOLUME" >/dev/null 2>&1 || true

# ── 3. PostgreSQL (development) ──────────────────────────────────────────────
if running pg-dev; then
  step "pg-dev already running"
else
  step "starting pg-dev ($POSTGRES_IMAGE)…"
  docker rm -f pg-dev >/dev/null 2>&1 || true
  docker run -d --name pg-dev --restart unless-stopped \
    --network "$SBX_NET_NAME" \
    -p 127.0.0.1:"$PG_PORT":5432 \
    -v "$PGDATA_VOLUME":/var/lib/postgresql/data \
    -e POSTGRES_USER -e POSTGRES_PASSWORD -e POSTGRES_DB \
    "$POSTGRES_IMAGE" >/dev/null
fi

# ── 4. PostgreSQL admin (Adminer) ────────────────────────────────────────────
if running adminer-dev; then
  step "adminer-dev already running"
else
  step "starting adminer-dev ($ADMINER_IMAGE)…"
  docker rm -f adminer-dev >/dev/null 2>&1 || true
  docker run -d --name adminer-dev --restart unless-stopped \
    --network "$SBX_NET_NAME" \
    -p 127.0.0.1:"$ADMINER_PORT":8080 \
    -e ADMINER_DEFAULT_SERVER \
    "$ADMINER_IMAGE" >/dev/null
fi

# ── 5. pi ↔ local AI on the host (models.json) ───────────────────────────────
step "writing pi provider config ($AI_PROVIDER)…"
case "$AI_PROVIDER" in
  model-runner) _base_url="$AI_MODEL_RUNNER_URL" ;;
  *)            _base_url="${AI_OLLAMA_URL%/}/v1" ;;
esac
mkdir -p /home/agent/.pi/agent
sed -e "s|__AI_BASE_URL__|$_base_url|g" \
    -e "s|__AI_MODEL__|$AI_OLLAMA_MODEL|g" \
    /home/agent/pi-models.template.json > /home/agent/.pi/agent/models.json
ok "pi → $_base_url (model: $AI_OLLAMA_MODEL)"

# ── 6. Workspaces: deps, env files, dev servers ──────────────────────────────
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
VITE_API_BASE=$VITE_API_BASE
EOF
}

for _app in api web; do
  if [ ! -d "$DEVSTACK_ROOT/$_app/node_modules" ]; then
    step "installing $_app dependencies (first run)…"
    (cd "$DEVSTACK_ROOT/$_app" && npm install --no-audit --no-fund) \
      > "$LOGDIR/npm-$_app.log" 2>&1 \
      || fail "npm install failed for $_app — see workspaces/logs/npm-$_app.log"
  fi
done

write_api_env
write_web_env

step "starting dev servers…"
pkill -f "tsx watch src/index.ts" >/dev/null 2>&1 || true
( cd "$DEVSTACK_ROOT/api" && nohup npm run dev > "$LOGDIR/api.log" 2>&1 & )
pkill -f "vite" >/dev/null 2>&1 || true
( cd "$DEVSTACK_ROOT/web" && nohup npm run dev > "$LOGDIR/web.log" 2>&1 & )

# ── 7. Health checks ─────────────────────────────────────────────────────────
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

step "waiting for services…"
for _ in $(seq 1 30); do
  [ "$(api_status)" = "ready" ] && [ "$(pg_status)" = "ready" ] && break
  sleep 1
done

# ── 8. Summary ───────────────────────────────────────────────────────────────
printf '\n'
printf '\033[1mdevstack components (inside the sandbox)\033[0m\n'
printf '  postgres  : %-8s pg-dev           127.0.0.1:%s  (db: %s)\n' "$(pg_status)"     "$PG_PORT"     "$POSTGRES_DB"
printf '  admin     : %-8s adminer-dev     127.0.0.1:%s  (server: %s)\n' "$(adminer_status)" "$ADMINER_PORT" "$POSTGRES_HOST"
printf '  api       : %-8s express/tsx    127.0.0.1:%s  (log: logs/api.log)\n' "$(api_status)"     "$API_PORT"
printf '  web       : %-8s vite/react     127.0.0.1:%s  (log: logs/web.log)\n' "$(web_status)"     "$WEB_PORT"
printf '  local ai  : %-8s %s  (model: %s)\n' "$AI_PROVIDER" "$_base_url" "$AI_OLLAMA_MODEL"
printf '\n'
printf 'agent tools: pi (/model → ollama), herdr (ctrl+b q to detach), openspec\n'
printf 're-run anytime: bash /home/agent/bootstrap/10-devstack.sh\n'

if [ "$(api_status)" != "ready" ]; then
  printf '\033[1;33m[devstack] api not ready — last log lines:\033[0m\n' >&2
  tail -n 20 "$LOGDIR/api.log" >&2 || true
  exit 1
fi
ok "devstack is up — API ↔ Postgres round-trip verified via /api/health"
