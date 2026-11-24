#!/usr/bin/env bash
# __ aienv.sh - one official Docker Sandbox per repository, with pi + herdr _____
# Built on Docker's `sbx` CLI (https://docs.docker.com/ai/sandboxes/): each
# environment is an isolated sandbox with its own VM runtime, host-side network
# proxy and per-sandbox policy rules. Commands:
#   new attach exec ls stop rm policy netbird diag   (see aienv.sh help)
# Our scripts always carry .sh so the bare `sbx` name stays Docker's (Regola 2).
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PROG=aienv.sh
USAGE="Usage: $PROG <command>

  new [PATH] [NAME]      create a sandbox for PATH (default: \$WORKSPACE), provision pi + herdr
  attach NAME            open the sandbox session (sbx run --name NAME)
  exec NAME CMD...       run a command inside the sandbox (interactive TTY when attached to a terminal)
  ls [NAME]              list sandboxes; with NAME show its published ports
  stop NAME...           stop one or more sandboxes
  rm NAME...             remove sandboxes (sbx asks for confirmation)
  policy ...             manage network rules (init | show | stack | allow | deny | rm | check | log)
  netbird                show the host's NetBird status (mesh peer for AI_SERVER_URL)
  diag                   preflight checks (sbx, KVM, daemon, policy, Ollama)
  version | help"

load_env  # toolkit layer; project overrides are loaded where the project is known

# __ new ________________________________________________________________________
cmd_new() {
  local ws=${1:-${WORKSPACE:-}}
  local raw_name=${2:-}
  [[ -n $ws ]] || die "Usage: $PROG new [PATH] [NAME]  (or set WORKSPACE in etc.env)"
  [[ -d $ws ]] || die "Workspace not found: $ws"
  ws=$(cd "$ws" && pwd)

  local name
  name=$(sandbox_name_fix "${raw_name:-$(basename "$ws")}") \
    || die "Cannot derive a valid sandbox name from '${raw_name:-$(basename "$ws")}' (2-63 chars [A-Za-z0-9.-], dot-parts start/end alnum)."
  local proj; proj=$(project_dir "$name")
  mkdir -p "$proj"
  load_env "$proj"  # per-project overrides (if the project already had files)

  # seed the per-project config (Msg 9: etc.env committable, .env private)
  if [[ ! -f $proj/etc.env ]]; then
    cat > "$proj/etc.env" <<EOF
# aienv per-project settings - COMMITTABLE (secrets belong in .env)
CPUS=$CPUS
MEMORY=$MEMORY
AI_SERVER_URL=$AI_SERVER_URL
AI_MODELS=$AI_MODELS
PREVIEW_PORTS=$PREVIEW_PORTS
SBX_TEMPLATE=$SBX_TEMPLATE
TZ=$TZ
EOF
    ok "Project config written: $proj/etc.env (commit it in your repo if you like)"
  fi
  if [[ ! -f $proj/.env && -n ${GITHUB_TOKEN:-} ]]; then
    printf 'GITHUB_TOKEN=%s\n' "$GITHUB_TOKEN" > "$proj/.env"
    chmod 600 "$proj/.env"
    ok "Private token written: $proj/.env (never commit)"
  fi

  need_sbx
  if sbx inspect "$name" >/dev/null 2>&1; then
    die "Sandbox '$name' already exists - remove it first (aienv.sh rm $name) or pick another name."
  fi

  step "Creating sandbox '$name' (agent: shell, workspace: $ws)"
  local args=(create --name "$name" --cpus "$CPUS" -m "$MEMORY")
  local p
  for p in $PREVIEW_PORTS; do args+=(-p "$p"); done
  args+=(-e "AI_SERVER_URL=$AI_SERVER_URL" -e "AI_MODELS=$AI_MODELS" -e "TZ=$TZ")
  if [[ -n $SBX_TEMPLATE ]]; then args+=(-t "$SBX_TEMPLATE"); fi
  if [[ -f $proj/.env ]]; then args+=(--env-file "$proj/.env"); fi
  args+=(shell "$ws")
  sbx "${args[@]}"

  step "Applying network rules for the stack (scoped to '$name')"
  cmd_policy_stack "$name"

  step "Provisioning pi + herdr inside the sandbox"
  sbx exec -i "$name" bash -s < "$AIENV_ROOT/provision.sh"

  ok "Sandbox '$name' ready."
  echo "    attach:   $PROG attach $name      then run 'pi' or 'herdr' in the session"
  echo "    ports:    $PROG ls $name           (preview ports, host ports picked by the OS)"
  echo "    rules:    $PROG policy show $name"
}

# __ attach / exec / ls / stop / rm _____________________________________________
cmd_attach() {
  [[ $# -ge 1 ]] || die "Usage: $PROG attach NAME"
  require_sandbox "$1"
  exec sbx run --name "$1"
}

cmd_exec() {
  [[ $# -ge 2 ]] || die "Usage: $PROG exec NAME COMMAND..."
  local name=$1; shift
  require_sandbox "$name"
  if [[ -t 0 ]]; then exec sbx exec -it "$name" "$@"; else exec sbx exec "$name" "$@"; fi
}

cmd_ls() {
  need_sbx
  if [[ $# -ge 1 ]]; then
    require_sandbox "$1"
    sbx inspect "$1"
    echo
    sbx port ls "$1"
  else
    sbx ls
  fi
}

cmd_stop() { need_sbx; [[ $# -ge 1 ]] || die "Usage: $PROG stop NAME..."; sbx stop "$@"; }
cmd_rm()   { need_sbx; [[ $# -ge 1 ]] || die "Usage: $PROG rm NAME...";   sbx rm "$@"; }

# __ policy _____________________________________________________________________
# Preset (global, first setup only) + per-sandbox rules. Syntax verified against
# https://docs.docker.com/ai/governance/local/network-rules/.
cmd_policy_init() {   # $1 = preset (optional)
  need_sbx
  sbx policy init "${1:-${POLICY_PRESET:-balanced}}"
  ok "Preset set: ${1:-${POLICY_PRESET:-balanced}} (change later with: sbx policy reset)"
}

cmd_policy_show() {
  need_sbx
  if [[ $# -ge 1 ]]; then sbx policy ls "$1"; else sbx policy ls; fi
}

cmd_policy_stack() {  # $1 = sandbox; adds the stack's allow rules, scoped to it
  local name=$1
  load_env "$(project_dir "$name")"  # project AI_SERVER_URL / EXTRA_ALLOW override
  local d existing
  existing=$(sbx policy ls "$name" 2>/dev/null || true)
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if grep -qF "$d" <<< "$existing"; then
      echo "  = $d (already allowed)"
    else
      sbx policy allow network --sandbox "$name" "$d" >/dev/null 2>&1 \
        || die "Could not add allow rule for '$d' (run: sbx policy allow network --sandbox $name $d)"
      echo "  + $d"
    fi
  done < <(stack_destinations)
}

cmd_policy() {
  local sub=${1:-}; shift || true
  case $sub in
    init)  cmd_policy_init "$@" ;;
    show)  cmd_policy_show "$@" ;;
    stack) [[ $# -ge 1 ]] || die "Usage: $PROG policy stack NAME"; cmd_policy_stack "$1" ;;
    allow) need_sbx; [[ $# -ge 2 ]] || die "Usage: $PROG policy allow NAME DEST"; sbx policy allow network --sandbox "$1" "$2" ;;
    deny)  need_sbx; [[ $# -ge 2 ]] || die "Usage: $PROG policy deny NAME DEST";  sbx policy deny  network --sandbox "$1" "$2" ;;
    rm)    need_sbx; [[ $# -ge 2 ]] || die "Usage: $PROG policy rm NAME DEST";    sbx policy rm network --sandbox "$1" --resource "$2" ;;
    check) need_sbx; [[ $# -ge 1 ]] || die "Usage: $PROG policy check DEST";      sbx policy check network "$1" ;;
    log)   need_sbx; sbx policy log ;;
    *) die "Usage: $PROG policy <init|show|stack|allow|deny|rm|check|log>" ;;
  esac
}

# __ netbird ____________________________________________________________________
cmd_netbird() {
  command -v netbird >/dev/null 2>&1 \
    || die "netbird not found on this host. The host is your ONLY mesh peer - the sandboxes stay VPN-free. Install/enroll once: https://docs.netbird.io"
  netbird status
  echo
  echo "  Mesh rule (unchanged from v3.1): the host is the single peer; sandboxes"
  echo "  are reached through it and never join the mesh themselves."
  echo "  AI on ANOTHER machine? Set AI_SERVER_URL to its MagicDNS name or 100.x IP"
  echo "  in etc.env, then: $PROG policy stack <name>"
}

# __ diag _______________________________________________________________________
cmd_diag() {
  local fails=0 url

  echo "${C_DIM}aienv preflight on $(hostname) - $(date '+%Y-%m-%d %H:%M')${C_0}"
  echo

  # 1. official CLI
  if command -v sbx >/dev/null 2>&1; then
    ok "sbx CLI: $(sbx version 2>/dev/null | head -1 || echo present)"
  else
    warn "sbx CLI missing - install: curl -fsSL https://get.docker.com | sudo SBX=1 sh"; fails=$((fails+1))
  fi

  # 2. KVM: local sandboxes require it (Docker docs: install/prerequisites)
  if [[ -e /dev/kvm ]]; then
    if id -nG | grep -qw kvm; then
      ok "KVM: /dev/kvm present, user in 'kvm' group"
    else
      warn "user NOT in 'kvm' group - fix: sudo usermod -aG kvm \$USER, then re-login"; fails=$((fails+1))
    fi
  else
    warn "/dev/kvm missing - local sandboxes cannot start (KVM required; cloud sandboxes work without)"; fails=$((fails+1))
  fi

  # 3. daemon + login sanity
  load_env
  if command -v sbx >/dev/null 2>&1; then
    if sbx ls >/dev/null 2>&1; then
      ok "sandboxd daemon responsive (sbx ls)"
    else
      warn "sbx ls failed - run 'sbx login' once, then 'sbx diagnose'"; fails=$((fails+1))
    fi
  fi

  # 4. policy
  if command -v sbx >/dev/null 2>&1 && sbx policy ls >/dev/null 2>&1; then
    ok "local policy readable (preset + rules)"
  else
    warn "policy not initialized - run: $PROG policy init (${POLICY_PRESET:-balanced})"
  fi

  # 5. Ollama, probed host-side (the sandbox proxy forwards to host localhost)
  url=${AI_SERVER_URL/#http:\/\/host.docker.internal/http://localhost}
  if curl -fsS -m 5 "$url" >/dev/null 2>&1; then
    ok "AI server reachable from host: $url (sandboxes reach it via host.docker.internal)"
  else
    warn "AI server not reachable at $url - is 'ollama serve' running? Models: ollama pull ${AI_MODELS%% *}"
  fi

  # 6. mesh (informational)
  if command -v netbird >/dev/null 2>&1; then
    ok "netbird installed ($(netbird status 2>/dev/null | head -1))"
  else
    echo "${C_DIM}  netbird not installed (optional: mesh access to published ports / remote AI)${C_0}"
  fi

  # 7. secrets file
  if [[ -f $AIENV_ROOT/.env ]]; then
    ok ".env present (chmod $(stat -c %a "$AIENV_ROOT/.env"))"
  else
    warn ".env missing - copy: cp .env.example .env && chmod 600 .env"
  fi

  echo
  if (( fails > 0 )); then die "diag: $fails blocking issue(s) above."; fi
  ok "diag: no blocking issues."
}

# __ entry ______________________________________________________________________
cmd_help() { echo "$USAGE"; }
cmd_version() { echo "aienv 1.0 (Docker Sandboxes)"; command -v sbx >/dev/null 2>&1 && sbx version | head -1; }

cmd=${1:-help}
if [[ $# -gt 0 ]]; then shift; fi
case $cmd in
  new)     cmd_new "$@" ;;
  attach)  cmd_attach "$@" ;;
  exec)    cmd_exec "$@" ;;
  ls)      cmd_ls "$@" ;;
  stop)    cmd_stop "$@" ;;
  rm)      cmd_rm "$@" ;;
  policy)  cmd_policy "$@" ;;
  netbird) cmd_netbird "$@" ;;
  diag)    cmd_diag "$@" ;;
  version) cmd_version ;;
  help|-h|--help) cmd_help ;;
  *) die "Unknown command: '$cmd'. Run '$PROG help'." ;;
esac
