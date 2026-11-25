#!/usr/bin/env bash
# =============================================================================
# ./sbx.sh -- day-2 operator for the devstack Docker Sandbox (GitOps wrapper)
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
#   ./sbx.sh new NAME [dir]   copy the template into a new project named NAME
#
# All values come from etc.env; the declarative definition is sbxenv.yaml,
# kept at the repo root (sbx resolves its relative paths from its own dir).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# -- Load etc.env (single source of truth) ------------------------------------
if [ ! -f "$ROOT/etc.env" ]; then
  echo "etc.env not found -- creating it from etc.env.example (dev defaults)" >&2
  cp "$ROOT/etc.env.example" "$ROOT/etc.env"
fi
# shellcheck disable=SC1091
. "$ROOT/etc.env"

# -- One-name override: ./sbx.sh <command> --name weekly85 ---------------------
# Weekly projects: ONE name drives sandbox name, postgres volume, internal
# network and the default GitHub repo. See README "Project name".
SBX_NAME_CLI=""
_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name)   SBX_NAME_CLI="${2:-}"; shift 2 ;;
    --name=*) SBX_NAME_CLI="${1#--name=}"; shift ;;
    *)        _args+=("$1"); shift ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}
[ -n "$SBX_NAME_CLI" ] && SBX_NAME="$SBX_NAME_CLI"

# Derived per-project resource names (one name to rule them all).
PGDATA_VOLUME="$SBX_NAME-pgdata"
SBX_NET_NAME="$SBX_NAME-net"
GITHUB_REPO="${GITHUB_REPO:-$SBX_NAME}"
export SBX_NAME PGDATA_VOLUME SBX_NET_NAME GITHUB_REPO

require_sbx() {
  command -v sbx >/dev/null 2>&1 || {
    echo "ERROR: 'sbx' not found. Install Docker Sandboxes first -- see ./setup.sh" >&2
    exit 1
  }
}

ENV_FILE="$ROOT/$SBX_ENV_FILE"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }

# -- etc.env -> sandbox persistent env (/etc/sandbox-persistent.sh) ------------
# The sandbox sources this file on every shell, so it is authoritative at
# runtime; the env: block of sbxenv.yaml is only a fallback.
PERSIST_KEYS=(
  SBX_NAME
  AI_PROVIDER AI_OLLAMA_URL AI_OLLAMA_MODEL AI_MODEL_RUNNER_URL
  SBX_NET_NAME PGDATA_VOLUME
  POSTGRES_IMAGE POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_HOST PG_PORT
  ADMINER_IMAGE ADMINER_PORT ADMINER_DEFAULT_SERVER
  API_PORT WEB_PORT VITE_API_BASE NODE_ENV
  GITHUB_OWNER GITHUB_REPO GITHUB_TOKEN GIT_USER_NAME GIT_USER_EMAIL
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
    echo "- synced etc.env -> /etc/sandbox-persistent.sh"
  else
    echo "[warn] could not sync etc.env into the sandbox; the env: block of" >&2
    echo "  sbxenv.yaml will be used as fallback (keep both in sync)." >&2
  fi
  rm -f "$tmp"
}

sandbox_exists() { sbx inspect "$SBX_NAME" >/dev/null 2>&1; }

# -- Pre-flight check: prove every path/port BEFORE sbx resolves them ---------
# sbx resolves relative paths in sbxenv.yaml from the env file's OWN directory
# (fileDir), not from the cwd. This template keeps sbxenv.yaml at the repo
# root; `check` prints exactly what sbx will see, so failures are
# self-explanatory instead of a bare "kit path ... does not exist".
do_check() {
  local fail=0

  echo "- env file  : $ENV_FILE"
  [ -f "$ENV_FILE" ] || { echo "  [FAIL] missing"; fail=1; }

  # Kit entries (relative paths like ./kit/devstack)
  local kit_rel kit_dir kit_name
  for kit_rel in $(grep -E '^[[:space:]]*-[[:space:]]+\./' "$ENV_FILE" 2>/dev/null \
                     | sed -E 's/^[[:space:]]*-[[:space:]]+//; s/"//g'); do
    kit_dir="$ROOT/$kit_rel"
    kit_name="$(basename "$kit_rel")"
    echo "- kit       : $kit_dir"
    if [ ! -d "$kit_dir" ]; then
      echo "  [FAIL] directory missing -- sbx would fail with 'kit path ... does not exist'"
      fail=1
      continue
    fi
    for _ext in yaml dockerfile; do
      if [ ! -f "$kit_dir/$kit_name.$_ext" ]; then
        echo "  [FAIL] $kit_name.$_ext missing"; fail=1
        continue
      fi
      # Two rules proven by sbx 0.54: the DESCRIPTOR yaml is the build
      # definition and must START with the frontend directive, else buildkit
      # parses it with the default Dockerfile parser ("unknown instruction:
      # schemaVersion:"). The companion RECIPE must be an ORDINARY Dockerfile
      # with no directive at all ("content recipe ... names the kit frontend
      # in its syntax directive" otherwise).
      if [ "$_ext" = "yaml" ]; then
        if [ "$(head -n1 "$kit_dir/$kit_name.yaml")" = "# syntax=docker/sandbox-kit:3" ]; then
          echo "  [ok] $kit_name.yaml (frontend directive on line 1)"
        else
          echo "  [FAIL] $kit_name.yaml must START with '# syntax=docker/sandbox-kit:3'"
          fail=1
        fi
      else
        if grep -q '^# syntax=' "$kit_dir/$kit_name.dockerfile"; then
          echo "  [FAIL] $kit_name.dockerfile must be an ORDINARY Dockerfile - remove its '# syntax=' line (directive belongs only in $kit_name.yaml)"
          fail=1
        else
          echo "  [ok] $kit_name.dockerfile (ordinary recipe, no syntax directive)"
        fi
      fi
    done
  done

  # Primary workspace (declared as `workspace: ./workspaces`)
  local ws_rel
  ws_rel="$(grep -E '^workspace:' "$ENV_FILE" 2>/dev/null | awk '{print $2}' | tr -d '"')"
  if [ -n "$ws_rel" ]; then
    echo "- workspace : $ROOT/$ws_rel"
    if [ ! -d "$ROOT/$ws_rel" ]; then
      echo "  [FAIL] directory missing"; fail=1
    else
      [ -d "$ROOT/$ws_rel/api" ] && echo "  [ok] workspaces/api" || { echo "  [FAIL] workspaces/api missing"; fail=1; }
      [ -d "$ROOT/$ws_rel/web" ] && echo "  [ok] workspaces/web" || { echo "  [FAIL] workspaces/web missing"; fail=1; }
    fi
  fi

  # Cross-file consistency: sandbox name + published ports (etc.env <-> sbxenv.yaml)
  if grep -qE "^name:[[:space:]]*$SBX_NAME[[:space:]]*$" "$ENV_FILE"; then
    echo "- name      : '$SBX_NAME' matches sbxenv.yaml"
  else
    echo "  [warn] sbxenv.yaml 'name:' differs from SBX_NAME=$SBX_NAME"
    echo "         --name overrides it at plan/create time; edit sbxenv.yaml"
    echo "         'name:' to make the new name the committed default"
  fi
  # Host ports must be FREE: sbx publishes them when the sandbox container
  # starts; an occupied port fails the run AFTER the (slow) kit build.
  local p listen addr busy
  if command -v ss >/dev/null 2>&1; then
    listen="$(ss -ltnH 2>/dev/null | awk '{print $4}')"
  elif command -v lsof >/dev/null 2>&1; then
    listen="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}')"
  else
    listen=""
    echo "- ports     : (neither ss nor lsof found -- skipped the free-port check)"
  fi
  for p in "$PG_PORT" "$API_PORT" "$WEB_PORT" "$ADMINER_PORT"; do
    if grep -qE "^[[:space:]]*-[[:space:]]*sandbox:[[:space:]]*$p[[:space:]]*$" "$ENV_FILE" \
       && grep -qE "^[[:space:]]*host:[[:space:]]*$p[[:space:]]*$" "$ENV_FILE"; then
      busy=0
      for addr in $listen; do
        case "${addr##*:}" in "$p") busy=1 ;; esac
      done
      if [ "$busy" = 1 ]; then
        echo "  [FAIL] host port $p is ALREADY IN USE -- sbx publishes it on the"
        echo "         host, and the run would fail after the kit build; free the"
        echo "         port or change the host side in etc.env + sbxenv.yaml"
        fail=1
      else
        echo "- port      : $p declared (sandbox -> host) and free on the host"
      fi
    else
      echo "  [FAIL] port $p not declared for BOTH sandbox and host in sbxenv.yaml"; fail=1
    fi
  done

  if [ "$fail" -ne 0 ]; then
    echo "[FAIL] check FAILED -- fix the items marked [FAIL], then re-run" >&2
    return 1
  fi
  echo "[ok] check OK -- every path and port resolves the way sbx will resolve it"
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
    echo "- sandbox '$SBX_NAME' already exists (sbx ls / sbx attach if stopped)"
  else
    echo "- creating sandbox from $ENV_FILE (first run builds the kit image)..."
    if ! sbx env create "$ENV_FILE" --name "$SBX_NAME"; then
      echo "[FAIL] sbx env create failed - the three most common causes:" >&2
      echo "  1. kit recipe error -> <name>.yaml must START with" >&2
      echo "     '# syntax=docker/sandbox-kit:3' AND <name>.dockerfile must be an" >&2
      echo "     ordinary Dockerfile with NO '# syntax=' line ('./sbx.sh check'" >&2
      echo "     verifies both);" >&2
      echo "  2. path resolution -> sbx resolves relative paths in sbxenv.yaml" >&2
      echo "     from the env file's OWN directory ('./sbx.sh check' prints them);" >&2
      echo "  3. 'failed to run sandbox container' after 'image ready' -> the real" >&2
      echo "     cause is in the sbx daemon log: ./sbx.sh daemonlog (loop devices," >&2
      echo "     erofs, PATH -- re-run ./setup.sh; it verifies all of them)." >&2
      exit 1
    fi
  fi

  sync_env_to_sandbox

  echo "- running in-sandbox bootstrap..."
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
  sandbox_exists && sbx inspect "$SBX_NAME" || echo "sandbox '$SBX_NAME' does not exist yet -- run './sbx.sh up'"
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
$SBX_NAME URLs (host side -- published by sbxenv.yaml ports:)
  web      : http://localhost:$WEB_PORT
  api      : http://localhost:$API_PORT/api/health
  adminer  : http://localhost:$ADMINER_PORT  (server: $POSTGRES_HOST, user: $POSTGRES_USER)
  postgres : localhost:$PG_PORT ($POSTGRES_USER/$POSTGRES_PASSWORD -> $POSTGRES_DB)
EOF
}

cmd_ai() {
  require_sbx
  echo "- from HOST -> $AI_OLLAMA_URL"
  curl -fsS -m 5 "$AI_OLLAMA_URL/api/tags" | head -c 400 || {
    echo "[warn] host cannot reach Ollama at $AI_OLLAMA_URL" >&2
    echo "  (is ollama running? is it bound to $OLLAMA_BIND_HOST? see ./setup.sh)" >&2
  } || true
  echo
  echo "- from SANDBOX -> $AI_OLLAMA_URL (network policy must allow it)"
  sbx exec "$SBX_NAME" bash -c "curl -fsS -m 5 '$AI_OLLAMA_URL/api/tags' | head -c 400" || {
    echo "[warn] sandbox cannot reach the host AI endpoint -- check:" >&2
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

cmd_daemonlog() {
  local log="$HOME/.local/state/sandboxes/sandboxes/sandboxd/daemon.log"
  if [ -f "$log" ]; then
    echo "- sbx daemon log: $log"
    echo "  (the real error behind 'failed to run sandbox container' is here)"
    echo
    grep -iE 'error|warn' "$log" | tail -n 30 || tail -n 30 "$log"
  else
    echo "no daemon log at $log" >&2
    echo "try: sbx diagnose" >&2
  fi
}

cmd_rm() {
  require_sbx
  if sbx env rm "$ENV_FILE" --name "$SBX_NAME" "$@"; then
    echo "note: the Postgres volume '$PGDATA_VOLUME' survives -- wipe it with:"
    echo "  ./sbx.sh up && ./sbx.sh exec docker volume rm $PGDATA_VOLUME"
  else
    echo "(sbx reports nothing to remove for '$SBX_NAME' -- a failed create"
    echo " usually cleans up after itself; the built kit image stays cached)"
  fi
}

cmd_new() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "usage: ./sbx.sh new <project-name> [target-dir]  # e.g. ./sbx.sh new weekly85" >&2
    exit 2
  fi
  local target="${2:-$ROOT/../../$name}"
  if [ -e "$target" ]; then
    echo "[FAIL] target already exists: $target" >&2
    exit 1
  fi
  mkdir -p "$target"
  # Copy the committed template WITHOUT local state (deps, logs, git, env).
  tar -C "$ROOT" --exclude='.git' --exclude='node_modules' --exclude='dist' \
      --exclude='etc.env' --exclude='*.log' --exclude='.env' \
      --exclude='env' -cf - . | tar -C "$target" -xf -
  sed "s/^SBX_NAME=.*/SBX_NAME=$name/" "$ROOT/etc.env.example" > "$target/etc.env"
  echo "- new project: $target"
  echo "  sandbox '$name' | volume '$name-pgdata' | net '$name-net' | default GitHub repo '$name'"
  echo "next:"
  echo "  cd $target"
  echo "  # put the fine-grained GitHub token scoped to the '$name' repo into etc.env"
  echo "  ./setup.sh && ./sbx.sh up"
}

cmd_reset() {
  cmd_rm --force
}

usage() {
  cat <<'EOF'
./sbx.sh -- day-2 operator for the devstack Docker Sandbox (GitOps wrapper)

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
  ./sbx.sh daemonlog  tail the sbx daemon log (real cause of run failures)
  ./sbx.sh db       psql shell inside the sandbox
  ./sbx.sh down     stop the sandbox (keep state)
  ./sbx.sh rm       remove the sandbox (destroys containers; volume persists)
  ./sbx.sh new NAME [dir]   copy the template into a new project named NAME
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
  daemonlog) shift; cmd_daemonlog ;;
  db)     shift; cmd_db ;;
  down)   shift; cmd_down ;;
  rm)     shift; cmd_rm "$@" ;;
  new)    shift; cmd_new "$@" ;;
  reset)  shift; cmd_reset ;;
  help|-h|--help) usage ;;
  *) echo "unknown command: $1" >&2; usage; exit 2 ;;
esac
