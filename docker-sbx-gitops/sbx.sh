#!/usr/bin/env bash
# =============================================================================
# ./sbx.sh — day-2 operator for the devstack Docker Sandbox (GitOps wrapper)
#
#   ./sbx.sh check    pre-flight: verify every path/port sbx will resolve
#   ./sbx.sh plan     show the sbx env apply plan (no changes)
#   ./sbx.sh up       create sandbox, sync etc.env, run bootstrap, health
#   ./sbx.sh shell    interactive shell inside the sandbox
#   ./sbx.sh exec CMD run a command inside the sandbox
#   ./sbx.sh status   sbx ls
#   ./sbx.sh ports    sbx port ls (published host ports)
#   ./sbx.sh logs X   follow logs: api | web | pg | adminer
#   ./sbx.sh url      print the host-side URLs
#   ./sbx.sh ai       verify host Ollama reachability (host + from sandbox)
#   ./sbx.sh db       psql shell inside the sandbox
#   ./sbx.sh down     stop the sandbox (keep state)
#   ./sbx.sh rm       remove the sandbox (destroys containers; volume persists)
#
# All values come from etc.env; the declarative definition is sbxenv.yaml,
# kept at the repo root (sbx resolves its relative paths from its own dir).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# ── Load etc.env (single source of truth) ────────────────────────────────────
if [ ! -f "$ROOT/etc.env" ]; then
  echo "etc.env not found — creating it from etc.env.example (dev defaults)" >&2
  cp "$ROOT/etc.env.example" "$ROOT/etc.env"
fi
# shellcheck disable=SC1091
. "$ROOT/etc.env"

require_sbx() {
  command -v sbx >/dev/null 2>&1 || {
    echo "ERROR: 'sbx' not found. Install Docker Sandboxes first — see ./setup.sh" >&2
    exit 1
  }
}

ENV_FILE="$ROOT/$SBX_ENV_FILE"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }

# ── etc.env → sandbox persistent env (/etc/sandbox-persistent.sh) ────────────
# The sandbox sources this file on every shell, so it is authoritative at
# runtime; the env: block of sbxenv.yaml is only a fallback.
PERSIST_KEYS=(
  AI_PROVIDER AI_OLLAMA_URL AI_OLLAMA_MODEL AI_MODEL_RUNNER_URL
  SBX_NET_NAME PGDATA_VOLUME
  POSTGRES_IMAGE POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_HOST PG_PORT
  ADMINER_IMAGE ADMINER_PORT ADMINER_DEFAULT_SERVER
  API_PORT WEB_PORT VITE_API_BASE NODE_ENV
)
persist_env_payload() {
  for _k in "${PERSIST_KEYS[@]}"; do
    printf 'export %s=%q\n' "$_k" "${!_k:-}"
  done
}

sync_env_to_sandbox() {
  local tmp; tmp="$(mktemp)"
  persist_env_payload > "$tmp"
  if sbx exec "$SBX_NAME" bash -c '
      cat > /tmp/.sbx-persistent.sh
      mv /tmp/.sbx-persistent.sh /etc/sandbox-persistent.sh 2>/dev/null \
        || sudo mv /tmp/.sbx-persistent.sh /etc/sandbox-persistent.sh' \
      < "$tmp" >/dev/null; then
    echo "• synced etc.env → /etc/sandbox-persistent.sh"
  else
    echo "⚠ could not sync etc.env into the sandbox; the env: block of" >&2
    echo "  sbxenv.yaml will be used as fallback (keep both in sync)." >&2
  fi
  rm -f "$tmp"
}

sandbox_exists() { sbx inspect "$SBX_NAME" >/dev/null 2>&1; }

# ── Pre-flight check: prove every path/port BEFORE sbx resolves them ─────────
# sbx resolves relative paths in sbxenv.yaml from the env file's OWN directory
# (fileDir), not from the cwd. This template keeps sbxenv.yaml at the repo
# root; `check` prints exactly what sbx will see, so failures are
# self-explanatory instead of a bare "kit path ... does not exist".
do_check() {
  local fail=0

  echo "• env file  : $ENV_FILE"
  [ -f "$ENV_FILE" ] || { echo "  ✗ missing"; fail=1; }

  # Kit entries (relative paths like ./kit/devstack)
  local kit_rel kit_dir kit_name
  for kit_rel in $(grep -E '^[[:space:]]*-[[:space:]]+\./' "$ENV_FILE" 2>/dev/null \
                     | sed -E 's/^[[:space:]]*-[[:space:]]+//; s/"//g'); do
    kit_dir="$ROOT/$kit_rel"
    kit_name="$(basename "$kit_rel")"
    echo "• kit       : $kit_dir"
    if [ ! -d "$kit_dir" ]; then
      echo "  ✗ directory missing — sbx would fail with 'kit path ... does not exist'"
      fail=1
      continue
    fi
    for _ext in yaml dockerfile; do
      if [ -f "$kit_dir/$kit_name.$_ext" ]; then
        echo "  ✓ $kit_name.$_ext"
      else
        echo "  ✗ $kit_name.$_ext missing"; fail=1
      fi
    done
  done

  # Primary workspace (declared as `workspace: ./workspaces`)
  local ws_rel
  ws_rel="$(grep -E '^workspace:' "$ENV_FILE" 2>/dev/null | awk '{print $2}' | tr -d '"')"
  if [ -n "$ws_rel" ]; then
    echo "• workspace : $ROOT/$ws_rel"
    if [ ! -d "$ROOT/$ws_rel" ]; then
      echo "  ✗ directory missing"; fail=1
    else
      [ -d "$ROOT/$ws_rel/api" ] && echo "  ✓ workspaces/api" || { echo "  ✗ workspaces/api missing"; fail=1; }
      [ -d "$ROOT/$ws_rel/web" ] && echo "  ✓ workspaces/web" || { echo "  ✗ workspaces/web missing"; fail=1; }
    fi
  fi

  # Cross-file consistency: sandbox name + published ports (etc.env ↔ sbxenv.yaml)
  if grep -qE "^name:[[:space:]]*$SBX_NAME[[:space:]]*$" "$ENV_FILE"; then
    echo "• name      : '$SBX_NAME' matches sbxenv.yaml"
  else
    echo "  ✗ sbxenv.yaml 'name:' differs from SBX_NAME=$SBX_NAME"; fail=1
  fi
  local p
  for p in "$PG_PORT" "$API_PORT" "$WEB_PORT" "$ADMINER_PORT"; do
    if grep -qE "^[[:space:]]*-[[:space:]]*sandbox:[[:space:]]*$p[[:space:]]*$" "$ENV_FILE" \
       && grep -qE "^[[:space:]]*host:[[:space:]]*$p[[:space:]]*$" "$ENV_FILE"; then
      echo "• port      : $p declared (sandbox → host)"
    else
      echo "  ✗ port $p not declared for BOTH sandbox and host in sbxenv.yaml"; fail=1
    fi
  done

  if [ "$fail" -ne 0 ]; then
    echo "✗ check FAILED — fix the items marked ✗, then re-run" >&2
    return 1
  fi
  echo "✓ check OK — every path and port resolves the way sbx will resolve it"
}

cmd_plan() {
  require_sbx
  do_check || exit 1
  echo
  sbx env plan "$ENV_FILE" --name "$SBX_NAME"
}

cmd_up() {
  require_sbx
  do_check || exit 1
  echo

  if sandbox_exists; then
    echo "• sandbox '$SBX_NAME' already exists (sbx ls / sbx attach if stopped)"
  else
    echo "• creating sandbox from $ENV_FILE (first run builds the kit image)…"
    if ! sbx env create "$ENV_FILE" --name "$SBX_NAME"; then
      echo "✗ sbx env create failed — the sbx error above names the exact resource" >&2
      echo "  it could not resolve. Remember: sbx resolves relative paths in" >&2
      echo "  sbxenv.yaml from the env file's OWN directory, not the repo root." >&2
      echo "  './sbx.sh check' prints every resolved path for comparison." >&2
      exit 1
    fi
  fi

  sync_env_to_sandbox

  echo "• running in-sandbox bootstrap…"
  sbx exec "$SBX_NAME" bash /home/agent/bootstrap/10-devstack.sh

  echo
  cmd_url
}

cmd_shell() {
  require_sbx
  sbx exec -it "$SBX_NAME" bash -l
}

cmd_exec() {
  require_sbx
  [ "$#" -gt 0 ] || { cmd_shell; return; }
  if [ -t 0 ]; then
    sbx exec -it "$SBX_NAME" "$@"
  else
    sbx exec "$SBX_NAME" "$@"
  fi
}

cmd_status() {
  require_sbx
  sbx ls
  echo
  sandbox_exists && sbx inspect "$SBX_NAME" || echo "sandbox '$SBX_NAME' does not exist yet — run './sbx.sh up'"
}

cmd_ports() {
  require_sbx
  sbx port ls "$SBX_NAME"
}

cmd_logs() {
  require_sbx
  case "${1:-}" in
    api)     sbx exec "$SBX_NAME" tail -n 100 -f /home/agent/workspaces/logs/api.log ;;
    web)     sbx exec "$SBX_NAME" tail -n 100 -f /home/agent/workspaces/logs/web.log ;;
    pg)      sbx exec "$SBX_NAME" docker logs --tail 100 -f pg-dev ;;
    adminer) sbx exec "$SBX_NAME" docker logs --tail 100 -f adminer-dev ;;
    *) echo "usage: ./sbx.sh logs api|web|pg|adminer" >&2; exit 2 ;;
  esac
}

cmd_url() {
  cat <<EOF
devstack URLs (host side — published by sbxenv.yaml ports:)
  web      : http://localhost:$WEB_PORT
  api      : http://localhost:$API_PORT/api/health
  adminer  : http://localhost:$ADMINER_PORT  (server: $POSTGRES_HOST, user: $POSTGRES_USER)
  postgres : localhost:$PG_PORT ($POSTGRES_USER/$POSTGRES_PASSWORD → $POSTGRES_DB)
EOF
}

cmd_ai() {
  require_sbx
  echo "• from HOST → $AI_OLLAMA_URL"
  curl -fsS -m 5 "$AI_OLLAMA_URL/api/tags" | head -c 400 || {
    echo "⚠ host cannot reach Ollama at $AI_OLLAMA_URL" >&2
    echo "  (is ollama running? is it bound to $OLLAMA_BIND_HOST? see ./setup.sh)" >&2
  } || true
  echo
  echo "• from SANDBOX → $AI_OLLAMA_URL (network policy must allow it)"
  sbx exec "$SBX_NAME" bash -c "curl -fsS -m 5 '$AI_OLLAMA_URL/api/tags' | head -c 400" || {
    echo "⚠ sandbox cannot reach the host AI endpoint — check:" >&2
    echo "    sbx policy allow network 'host.docker.internal:11434'" >&2
    echo "  and the allow list in kit/devstack/devstack.yaml" >&2
  } || true
  echo
}

cmd_db() {
  require_sbx
  sbx exec -it "$SBX_NAME" bash -c \
    "PGPASSWORD=\$POSTGRES_PASSWORD psql -h 127.0.0.1 -p \$PG_PORT -U \$POSTGRES_USER -d \$POSTGRES_DB"
}

cmd_down() {
  require_sbx
  sbx stop "$SBX_NAME"
}

cmd_rm() {
  require_sbx
  sbx env rm "$ENV_FILE" --name "$SBX_NAME" "$@"
  echo "note: the Postgres volume '$PGDATA_VOLUME' survives — wipe it with:"
  echo "  ./sbx.sh up && ./sbx.sh exec docker volume rm $PGDATA_VOLUME"
}

cmd_reset() {
  cmd_rm --force
}

usage() {
  cat <<'EOF'
./sbx.sh — day-2 operator for the devstack Docker Sandbox (GitOps wrapper)

  ./sbx.sh check    pre-flight: verify every path/port sbx will resolve
  ./sbx.sh plan     show the sbx env apply plan (no changes)
  ./sbx.sh up       create sandbox, sync etc.env, run bootstrap, health
  ./sbx.sh shell    interactive shell inside the sandbox
  ./sbx.sh exec CMD run a command inside the sandbox
  ./sbx.sh status   sbx ls
  ./sbx.sh ports    sbx port ls (published host ports)
  ./sbx.sh logs X   follow logs: api | web | pg | adminer
  ./sbx.sh url      print the host-side URLs
  ./sbx.sh ai       verify host Ollama reachability (host + from sandbox)
  ./sbx.sh db       psql shell inside the sandbox
  ./sbx.sh down     stop the sandbox (keep state)
  ./sbx.sh rm       remove the sandbox (destroys containers; volume persists)
EOF
}

case "${1:-help}" in
  check)  shift; do_check ;;
  plan)   shift; cmd_plan "$@" ;;
  up)     shift; cmd_up "$@" ;;
  shell)  shift; cmd_shell "$@" ;;
  exec)   shift; cmd_exec "$@" ;;
  status) shift; cmd_status ;;
  ports)  shift; cmd_ports ;;
  logs)   shift; cmd_logs "$@" ;;
  url)    shift; cmd_url ;;
  ai)     shift; cmd_ai ;;
  db)     shift; cmd_db ;;
  down)   shift; cmd_down ;;
  rm)     shift; cmd_rm "$@" ;;
  reset)  shift; cmd_reset ;;
  help|-h|--help) usage ;;
  *) echo "unknown command: $1" >&2; usage; exit 2 ;;
esac
