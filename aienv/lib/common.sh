#!/usr/bin/env bash
# ── lib/common.sh - shared helpers for the aienv toolkit ───────────────────────
set -euo pipefail

AIENV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_OFF=''
fi

msg()  { printf '%s\n' "${C_CYAN}»${C_OFF} $*"; }
ok()   { printf '%s\n' "${C_GREEN}✔${C_OFF} $*"; }
warn() { printf '%s\n' "${C_YELLOW}⚠${C_OFF} $*" >&2; }
err()  { printf '%s\n' "${C_RED}✖${C_OFF} $*" >&2; }
die()  { err "$*"; exit 1; }

# ── paths ───────────────────────────────────────────────────────────────────────
# Projects directory: $AIENV_PROJECTS > projects_dir in aienv.conf > <toolkit>/projects
_projects_dir_from_conf() {
  awk -F= '$1 == "projects_dir" { sub(/^[^=]*=/, "", $0); print $0; exit }' \
    "$AIENV_ROOT/config/aienv.conf" 2>/dev/null || true
}
AIENV_PROJECTS="${AIENV_PROJECTS:-$(_projects_dir_from_conf)}"
AIENV_PROJECTS="${AIENV_PROJECTS:-$AIENV_ROOT/projects}"
if [[ ! -d "$AIENV_PROJECTS" ]]; then
  mkdir -p "$AIENV_PROJECTS" 2>/dev/null || true
fi
AIENV_PROJECTS="$(cd "$AIENV_PROJECTS" 2>/dev/null && pwd -P || printf '%s' "$AIENV_PROJECTS")"

dir_project() { printf '%s/%s' "$AIENV_PROJECTS" "$1"; }
cont_name()   { printf 'aienv-%s' "$1"; }

name_valid() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,38}$ ]]
}

require_project() {
  name_valid "$1" || die "Invalid project name: '$1' (lowercase letters, digits and dashes only, max 39 chars)."
  [[ -d "$(dir_project "$1")" ]] || die "Project '$1' does not exist in $AIENV_PROJECTS - create it with: aienv create $1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command '$1'. $2"
}

docker_ready() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1
}

require_docker() {
  require_cmd docker "Install Docker: https://docs.docker.com/engine/install/"
  docker_ready || die "The Docker daemon is not responding - is the service running?"
}

require_image() {
  docker image inspect aienv-base:latest >/dev/null 2>&1 \
    || die "Missing image aienv-base:latest - build it once with: aienv install"
}

# compositional helper: run docker compose inside the project directory
compose_run() {
  local name=$1; shift
  (cd "$(dir_project "$name")" && docker compose "$@")
}

cont_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || printf 'absent'
}

token_set() { # true when a real PAT is present in the project's private .env
  local f; f="$(dir_project "$1")/.env"
  [[ -f "$f" ]] && ! grep -qE '^GITHUB_TOKEN=(PASTE_YOUR_TOKEN_HERE)?$' "$f"
}

# ── configuration layering ──────────────────────────────────────────────────────
# Precedence (first match wins):
#   1. <project>/.env            (private, never committed)
#   2. <project>/aienv.config    (committable project settings)
#   3. <toolkit>/config/aienv.secrets  (private fallbacks, gitignored)
#   4. <toolkit>/config/aienv.conf     (committable toolkit defaults)
# Commands working on a project set __AIENV_PROJECT before calling config_get.
config_get() {
  local key=$1 def=${2:-} v="" f
  local files=()
  if [[ -n "${__AIENV_PROJECT:-}" ]]; then
    files+=("$(dir_project "$__AIENV_PROJECT")/.env" "$(dir_project "$__AIENV_PROJECT")/aienv.config")
  fi
  files+=("$AIENV_ROOT/config/aienv.secrets" "$AIENV_ROOT/config/aienv.conf")
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    v=$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); print $0; exit }' "$f" 2>/dev/null) || v=""
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  done
  printf '%s' "$def"
}

# toolkit-level only (no project layer) - used by `create` before the project exists
toolkit_config_get() {
  local key=$1 def=${2:-} v="" f
  for f in "$AIENV_ROOT/config/aienv.secrets" "$AIENV_ROOT/config/aienv.conf"; do
    [[ -f "$f" ]] || continue
    v=$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, "", $0); print $0; exit }' "$f" 2>/dev/null) || v=""
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  done
  printf '%s' "$def"
}

# env_set <file> <KEY> <value> - update or append KEY=value (exact key match)
env_set() {
  local f=$1 k=$2 v=$3 tmp; tmp="$(mktemp)"
  awk -F= -v k="$k" -v v="$v" '
    $1 == k { print k "=" v; done=1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# env_get <file> <KEY> - print value (empty when missing)
env_get() {
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, "", $0); print $0; exit }' "$1" 2>/dev/null || true
}

# render_tpl <template> <output> <KEY> <value> [<KEY> <value>…]
# Replaces __KEY__ placeholders; values stay literal and may contain newlines.
render_tpl() {
  local tpl=$1 out=$2; shift 2
  if (( $# % 2 != 0 )); then
    die "render_tpl: KEY/VALUE arguments must come in pairs"
  fi
  local i j k v
  for ((i = 1; i <= $#; i += 2)); do
    k=${!i}
    j=$((i + 1))
    v=${!j}
    case "$k" in
      *[!A-Za-z0-9_]*) die "render_tpl: invalid placeholder key '$k' (letters, digits, underscore only)" ;;
    esac
    export "tplv_$k=$v"
  done
  awk '
    BEGIN {
      for (e in ENVIRON) {
        if (e ~ /^tplv_/) { K = substr(e, 6); V[K] = ENVIRON[e] }
      }
    }
    {
      line = $0
      for (k in V) {
        r = V[k]
        gsub(/\\/, "\\\\", r)
        gsub(/&/, "\\&", r)
        gsub("__" k "__", r, line)
      }
      print line
    }
  ' "$tpl" > "$out"
}

# write_over <target> <tmpfile> - replace file content WITHOUT changing the inode
# (bind-mounted files keep their inode, so running containers see the update)
write_over() {
  cat "$2" > "$1" && rm -f "$2"
}

# ── free port picking (pure bash, no external tools) ────────────────────────────
port_listening() { # true (0) when something answers on 127.0.0.1:<port>
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

pick_free_port() { # first free port starting from $1
  local p=$1
  while port_listening "$p"; do
    p=$((p + 1))
  done
  printf '%s' "$p"
}

# deterministic per-name starting port, so different projects land far apart
name_port_base() {
  local h
  h=$(printf '%s' "$1" | cksum | awk '{print $1 % 4000}')
  printf '%s' "$((30000 + h * 3))"
}

# render the pi models.json for a project from its AI_SERVER_URL + AI_MODELS
render_models_file() {
  local proj=$1
  local base models first="1" m out json_models=""
  base=$(env_get "$proj/.env" "AI_SERVER_URL")
  models=$(config_get "AI_MODELS" "qwen2.5-coder:3b qwen2.5-coder:7b")
  for m in $models; do
    [[ -n "$json_models" ]] && json_models+=", "
    json_models+="{ \"id\": \"$m\", \"contextWindow\": 32768, \"maxTokens\": 8192 }"
  done
  out=$(render_tpl "$AIENV_ROOT/templates/pi-models.json.tpl" "/dev/stdout" \
          "BASE_URL" "$base" "MODELS" "$json_models")
  printf '%s\n' "$out"
}
