#!/usr/bin/env bash
# __ lib/common.sh - shared helpers for aienv.sh ________________________________
# aienv = one Docker Sandboxes (official `sbx` CLI) per repository, with pi and
# herdr provisioned inside. Configuration follows the Msg 9 convention:
# <project>/.env > <project>/etc.env > <toolkit>/.env > <toolkit>/etc.env.
# Config files are PARSED, never sourced: values may be unquoted, multi-word
# and no code in a config file can execute.

# pretty output -------------------------------------------------------------
if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_DIM=$'\e[2m'; C_0=$'\e[0m'
else
  C_G=''; C_R=''; C_Y=''; C_B=''; C_DIM=''; C_0=''
fi
die()  { echo "${C_R}✗${C_0} $*" >&2; exit 1; }
ok()   { echo "${C_G}✓${C_0} $*"; }
warn() { echo "${C_Y}▲${C_0} $*" >&2; }
step() { echo "${C_B}▸${C_0} $*"; }

# toolkit layout ------------------------------------------------------------
# BASH_SOURCE[1] = the script that sourced us (aienv.sh, at the toolkit root)
AIENV_ROOT=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)

# the official Docker CLI we wrap; our own scripts always carry .sh (Regola 2)
need_sbx() {
  command -v sbx >/dev/null 2>&1 || die "Docker's 'sbx' CLI not found in PATH.
  Install (Ubuntu 24.04+):  curl -fsSL https://get.docker.com | sudo SBX=1 sh
  Then sign in once:        sbx login
  Full guide:               https://docs.docker.com/ai/sandboxes/install/"
}

# __ layered configuration (Msg 9) ______________________________________________
# extract KEY's value from one config file; first match wins. Handles values
# with spaces, optional single/double quotes, inline comments not allowed.
_env_parse() {  # $1 = file, $2 = KEY -> echoes value; rc 1 when absent
  local line key val
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%$'\r'}
    if [[ $line =~ ^[[:space:]]*# ]]; then continue; fi
    if [[ ! $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then continue; fi
    key=${BASH_REMATCH[2]}; val=${BASH_REMATCH[3]}
    if [[ $key != "$2" ]]; then continue; fi
    while [[ $val == \"*\" || $val == \'* ]]; do val=${val:1:${#val}-2}; done
    printf '%s\n' "$val"
    return 0
  done < "$1"
  return 1
}

cfg() {  # $1 = KEY, $2 = default, $3 = optional project dir.
         # Precedence: <proj>/.env > <proj>/etc.env > <toolkit>/.env > <toolkit>/etc.env
  local key=$1 def=$2 proj=${3:-} f val
  local files=()
  if [[ -n $proj ]]; then files+=("$proj/.env" "$proj/etc.env"); fi
  files+=("$AIENV_ROOT/.env" "$AIENV_ROOT/etc.env")
  for f in "${files[@]}"; do
    [[ -f $f ]] || continue
    val=$(_env_parse "$f" "$key") && { printf '%s\n' "$val"; return 0; }
  done
  printf '%s\n' "$def"
}

# set all config globals, honoring the Msg 9 layering
load_env() {  # $1 = optional project dir
  local proj=${1:-}
  CPUS=$(cfg CPUS 2 "$proj")
  MEMORY=$(cfg MEMORY 4g "$proj")
  POLICY_PRESET=$(cfg POLICY_PRESET balanced "$proj")
  AI_SERVER_URL=$(cfg AI_SERVER_URL "http://host.docker.internal:11434" "$proj")
  AI_MODELS=$(cfg AI_MODELS "qwen2.5-coder:3b qwen2.5-coder:7b" "$proj")
  EXTRA_ALLOW=$(cfg EXTRA_ALLOW "" "$proj")
  PREVIEW_PORTS=$(cfg PREVIEW_PORTS "3000 5173 8080" "$proj")
  SBX_TEMPLATE=$(cfg SBX_TEMPLATE "" "$proj")
  TZ=$(cfg TZ "Europe/Rome" "$proj")
  PROJECTS_DIR=$(cfg PROJECTS_DIR "" "$proj")
  WORKSPACE=$(cfg WORKSPACE "" "$proj")
  GITHUB_TOKEN=$(cfg GITHUB_TOKEN "" "$proj")
}

projects_root() { printf '%s\n' "${PROJECTS_DIR:-$AIENV_ROOT/projects}"; }
project_dir()   { printf '%s\n' "$(projects_root)/$1"; }

# sandbox naming rules from 'sbx create --name': 2-63 chars of [A-Za-z0-9.-],
# each dot-separated part must start and end with a letter or number,
# 'default' is reserved. Fix simple names by sanitizing; die if unfixable.
valid_sbx_name() {  # $1 = name
  local n=$1
  if [[ $n == default ]]; then return 1; fi
  if [[ ${#n} -ge 2 && ${#n} -le 63 && $n =~ ^[A-Za-z0-9.-]+$ ]]; then :; else return 1; fi
  if [[ $n == *..* ]]; then return 1; fi
  local part
  for part in ${n//./ }; do
    if [[ $part =~ ^[A-Za-z0-9] && $part =~ [A-Za-z0-9]$ ]]; then :; else return 1; fi
  done
  return 0
}

sandbox_name_fix() {  # $1 = raw name -> echoes a conforming name
  local n=$1
  n=${n//[^A-Za-z0-9.-]/-}
  while [[ $n == -* ]]; do n=${n#-}; done
  while [[ $n == *- ]]; do n=${n%-}; done
  if valid_sbx_name "$n"; then printf '%s\n' "$n"; return 0; fi
  n="ai-$n"
  if [[ ${#n} -le 63 ]] && valid_sbx_name "$n"; then printf '%s\n' "$n"; return 0; fi
  return 1
}

require_sandbox() {  # $1 = name; avoids 'sbx run --name' silently CREATING one
  need_sbx
  sbx inspect "$1" >/dev/null 2>&1 || die "Sandbox '$1' does not exist (aienv.sh ls lists what you have)."
}

# host:port destination for the policy allowlist, derived from AI_SERVER_URL.
# host.docker.internal is translated to 'localhost' by the sandbox proxy, so
# the rule must name localhost:<port> (Docker docs: Local services). A port in
# the URL is required - a rule without one would open every port on the host.
ai_destination() {  # echoes "host:port"; prints nothing when unusable
  local url=$AI_SERVER_URL host port
  [[ $url =~ ^https?://([^/:]+):([0-9]+) ]] || {
    warn "AI_SERVER_URL has no :port (add it, e.g. http://host.docker.internal:11434): $url"
    return 0
  }
  host=${BASH_REMATCH[1]}
  port=${BASH_REMATCH[2]}
  [[ $host == host.docker.internal ]] && host=localhost
  printf '%s:%s\n' "$host" "$port"
}

# the destinations the aienv stack always needs on top of the preset baseline:
# the AI server, the pi + herdr installers, and the NodeSource repo used by
# provision.sh when the sandbox image ships an older Node.
stack_destinations() {
  local d
  d=$(ai_destination)
  printf '%s\n' "$d" pi.dev herdr.dev deb.nodesource.com
  for d in ${EXTRA_ALLOW:-}; do printf '%s\n' "$d"; done
}
