#!/usr/bin/env bash
# ── lib/cmd_run.sh - enter/shell/pi/status/monitor + help ──────────────────────

_preview_lines() { # <name> - echo reachable preview URLs for a project
  local name=$1 proj; proj=$(dir_project "$name")
  local cfg="$proj/aienv.config"
  local ports hostports bind pub_prev peer p_arr h_arr i
  bind=$(env_get "$cfg" PREVIEW_BIND);        [[ -n "$bind" ]]        || bind="127.0.0.1"
  pub_prev=$(env_get "$cfg" PUBLISH_PREVIEW); [[ -n "$pub_prev" ]]    || pub_prev="1"
  ports=$(env_get "$cfg" PREVIEW_PORTS)
  hostports=$(env_get "$cfg" PREVIEW_HOST_PORTS)
  peer=$(docker exec "$(cont_name "$name")" netbird status 2>/dev/null \
         | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1) || peer=""
  if [[ "$pub_prev" == "1" && -n "$ports" ]]; then
    p_arr=($ports); h_arr=($hostports)
    for i in "${!p_arr[@]}"; do
      [[ $i -lt ${#h_arr[@]} ]] || break
      echo "    http://localhost:${h_arr[$i]}  (container port ${p_arr[$i]})"
      if [[ -n "$peer" ]]; then
        echo "    http://${peer}:${p_arr[$i]}  (via NetBird, from any mesh device)"
      fi
    done
  fi
  return 0
}

_ssh_targets() { # <name> - echo usable SSH targets for herdr remote machines
  local name=$1 proj; proj=$(dir_project "$name")
  local ssh_port peer
  ssh_port=$(env_get "$proj/aienv.config" SSH_HOST_PORT)
  peer=$(docker exec "$(cont_name "$name")" netbird status 2>/dev/null \
         | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1) || peer=""
  if [[ -n "$peer" ]]; then
    echo "    ssh dev@${peer}            (via NetBird - works from any mesh device)"
  fi
  if [[ -n "$ssh_port" ]]; then
    echo "    ssh dev@localhost -p ${ssh_port}   (from this host)"
  fi
  return 0
}

_short_repo() { # <workspace-dir>
  local u
  u=$(git -C "$1" remote get-url origin 2>/dev/null || true)
  if [[ -z "$u" ]]; then
    printf '(local init)'
  else
    u=${u%.git}; printf '%s' "${u##*[:/]}"
  fi
}

_require_running() { # <name>
  require_project "$1"
  require_docker
  [[ "$(cont_state "$(cont_name "$1")")" == running ]] \
    || die "Container '$(cont_name "$1")' is not running - start it with: aienv start $1"
}

cmd_enter() {
  [[ $# -ge 1 ]] || die "Usage: aienv enter <name> [--shell]"
  local name=$1 mode=${2:-}
  _require_running "$name"
  case "$mode" in
    "")
      exec docker exec -it -u dev -w /workspace "$(cont_name "$name")" bash -lc \
        'command -v herdr >/dev/null 2>&1 || { echo "⚠ herdr not found in the container PATH"; exec bash; }; exec herdr'
      ;;
    --shell) cmd_shell "$name" ;;
    *) die "Second argument must be --shell" ;;
  esac
}

cmd_shell() {
  [[ $# -eq 1 ]] || die "Usage: aienv shell <name>"
  _require_running "$1"
  exec docker exec -it -u dev -w /workspace "$(cont_name "$1")" bash -l
}

cmd_pi() {
  [[ $# -ge 1 ]] || die "Usage: aienv pi <name> [pi args...]"
  local name=$1; shift
  _require_running "$name"
  exec docker exec -it -u dev -w /workspace "$(cont_name "$name")" pi "$@"
}

cmd_status() {
  local docker_ok=0
  if docker_ready; then docker_ok=1; else warn "Docker not available: showing file-level info only."; fi

  printf '\n'
  printf '%-12s %-9s %-7s %-16s %-8s %-16s %-4s %s\n' \
    "PROJECT" "STATE" "TOKEN" "CPU/MEM" "NETBIRD" "PEER-IP" "AI" "REPO"
  printf '%.0s-' {1..90}; echo

  local d name cont state cpu mem nb peer ai repo ai_url tkn
  for d in "$AIENV_PROJECTS"/*/; do
    [[ -f "$d/docker-compose.yml" ]] || continue
    name=$(basename "$d")
    cont=$(cont_name "$name")
    state="n/a"
    cpu="-"; mem="-"; nb="-"; peer="-"; ai="-"; tkn="ok"
    if (( docker_ok )); then
      state=$(cont_state "$cont")
      if [[ "$state" == running ]]; then state="up"; fi
      if [[ "$state" == up ]]; then
        cpu=$(docker stats --no-stream --format '{{.CPUPerc}}' "$cont" 2>/dev/null || echo "-") || cpu="-"
        mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$cont" 2>/dev/null || echo "-") || mem="-"
        if docker exec "$cont" netbird status >/dev/null 2>&1; then
          nb="mesh"
          peer=$(docker exec "$cont" netbird status 2>/dev/null \
                 | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1) || peer="-"
          [[ -n "$peer" ]] || peer="-"
        fi
        __AIENV_PROJECT=$name
        ai_url=$(config_get AI_SERVER_URL "")
        if [[ -n "$ai_url" ]]; then
          code=$(docker exec "$cont" curl -s -o /dev/null -w '%{http_code}' \
                 --max-time 3 "$ai_url/" 2>/dev/null) || code="000"
          if [[ "$code" == 200 ]]; then ai="ok"; else ai="no"; fi
        fi
      fi
    fi
    if ! token_set "$name"; then tkn="MISSING"; fi
    repo=$(_short_repo "$d/workspace")
    printf '%-12s %-9s %-7s %-16s %-8s %-16s %-4s %s\n' \
      "$name" "$state" "$tkn" "$cpu / $mem" "$nb" "$peer" "$ai" "$repo"
    if [[ "$state" == up ]]; then
      _preview_lines "$name"
      _ssh_targets "$name"
      echo
    fi
  done

  printf '\n'
  echo "herdr: attach with 'aienv enter <name>' - panes are marked working / blocked / idle."
  echo "To watch ALL environments from ONE herdr window, add each environment as a herdr remote machine"
  echo "over SSH (targets printed above). Details: aienv monitor <name>"
}

cmd_monitor() {
  [[ $# -ge 1 ]] || die "Usage: aienv monitor <name> [--watch N]"
  local name=$1; shift
  local watch=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --watch) watch=${2:?}; [[ "$watch" =~ ^[0-9]+$ ]] || die "--watch needs a number of seconds"; shift 2 ;;
      *) die "Unknown option: '$1'" ;;
    esac
  done
  _require_running "$name"
  local cont; cont=$(cont_name "$name")

  while true; do
    (( watch > 0 )) && command -v clear >/dev/null 2>&1 && clear
    echo "── aienv monitor · $name · $(date '+%Y-%m-%d %H:%M:%S') $( [[ $watch -gt 0 ]] && echo "(refresh $watch s)" )"
    echo
    echo "Resources (container limit from aienv.config: MEM=$(config_get MEM_LIMIT 4g), CPU=$(config_get CPU_LIMIT 2.0)):"
    docker stats --no-stream --format '  CPU {{.CPUPerc}}  MEM {{.MemUsage}}  NET I/O {{.NetIO}}  PIDs {{.PIDs}}' "$cont" || true
    echo
    echo "Top processes inside the environment:"
    docker exec "$cont" ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -10 || true
    echo
    if docker exec "$cont" netbird status >/dev/null 2>&1; then
      echo "NetBird peer:"
      docker exec "$cont" netbird status 2>/dev/null | head -6 || true
    else
      echo "NetBird: not enrolled (aienv netbird enroll $name <SETUP_KEY> --url <management-url>)"
    fi
    echo
    echo "AI server reachability:"
    local ai_url code
    __AIENV_PROJECT=$name
    ai_url=$(config_get AI_SERVER_URL "")
    if [[ -n "$ai_url" ]]; then
      code=$(docker exec "$cont" curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$ai_url/" 2>/dev/null) || code="000"
      if [[ "$code" == 200 ]]; then
        echo "  ok - $ai_url"
      else
        echo "  UNREACHABLE ($code) - $ai_url"
      fi
    else
      echo "  AI_SERVER_URL not set in $(dir_project "$name")/.env"
    fi
    echo
    echo "Preview URLs:"
    _preview_lines "$name" | sed 's/^/ /'
    echo "SSH targets (for herdr remote machines):"
    _ssh_targets "$name" | sed 's/^/ /'
    echo
    echo "herdr: 'aienv enter $name' - panes show working / blocked / idle; detach with ctrl+b q."
    (( watch > 0 )) || break
    sleep "$watch"
  done
}

cmd_help() {
  cat <<'EOF'
aienv - isolated AI development environments (one container per project)

  aienv install [--node-image X]      build the shared aienv-base image (latest stable Node LTS)
  aienv create <name> [options]       create an environment: clone/init repo, config, start
  aienv render <name>                 re-render docker-compose.yml + pi-models.json after config edits
  aienv start <name>                  start an environment
  aienv stop <name>                   stop an environment (code stays; herdr sessions do not)
  aienv enter <name> [--shell]        attach herdr in the environment (--shell for plain bash)
  aienv pi <name> [args...]           run pi directly (e.g. aienv pi weekly85 -p "fix the build")
  aienv status                        overview of all environments (resources, mesh, preview, repo)
  aienv monitor <name> [--watch N]    live view: resources, top processes, mesh, AI server
  aienv models <name> [model]         show / change the Ollama model pi uses (default: qwen2.5-coder:3b)
  aienv netbird <name> enroll <KEY> [--url URL] | off | status | ip | logs | ssh
  aienv update                        rebuild the image (latest pi/herdr/NetBird/Node) and recreate running envs
  aienv destroy <name> [--all]        remove the environment (--all also deletes the folder, with confirmation)
  aienv help | version

Configuration layering (first match wins):
  1. <project>/.env               private  (token, setup key, AI server URL, SSH key)
  2. <project>/aienv.config       committable (ports, models, resources, TZ)
  3. <toolkit>/config/aienv.secrets  private fallbacks (gitignored)
  4. <toolkit>/config/aienv.conf     committable defaults
After editing config files: aienv render <name>, then aienv restart via stop+start (or recreate).
EOF
}
