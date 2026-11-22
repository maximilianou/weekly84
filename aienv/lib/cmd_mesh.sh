#!/usr/bin/env bash
# ── lib/cmd_mesh.sh - NetBird mesh peer and Ollama model management ────────────

cmd_netbird() {
  local USAGE="Usage: aienv netbird <name> <subcommand> [args]
  enroll <name> <SETUP_KEY> [--url URL]   register the setup key + management URL, recreate the container
  off <name>                              disable the NetBird peer of this environment
  status <name>                           show the NetBird client status inside the environment
  ip <name>                               show the mesh IP (100.x) of this environment's peer
  logs <name>                             tail the NetBird log inside the container
  ssh <name>                              print SSH targets for herdr remote machines"
  local sub=${1:-}; [[ -n "$sub" ]] || die "$USAGE"
  shift || true

  case "$sub" in
    enroll)
      [[ $# -ge 2 ]] || die "$USAGE"
      local name=$1 key=$2; shift 2
      local url=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --url) url=${2:?}; shift 2 ;;
          *)     die "Unknown option: '$1'" ;;
        esac
      done
      require_project "$name"
      [[ -n "$key" ]] || die "Setup key is missing."
      local proj; proj=$(dir_project "$name")
      if [[ -z "$url" ]]; then
        url=$(env_get "$proj/.env" "NB_MANAGEMENT_URL")
      fi
      [[ -n "$url" ]] || die "A management URL is required for self-hosted NetBird: add --url https://your-management-url"
      [[ "$url" == http://* || "$url" == https://* ]] || die "Invalid management URL: '$url' (expected http(s)://...)"
      env_set "$proj/.env" "NETBIRD_SETUP_KEY" "$key"
      env_set "$proj/.env" "NB_MANAGEMENT_URL" "$url"
      chmod 600 "$proj/.env"
      ok "NetBird configuration saved to $proj/.env"
      require_docker
      require_image
      msg "Recreating the environment so the entrypoint can enroll the peer..."
      compose_run "$name" up -d --force-recreate
      sleep 3
      "$0" netbird "$name" status || true
      "$0" netbird "$name" ssh || true
      ;;

    off)
      [[ $# -eq 1 ]] || die "$USAGE"
      local name=$1
      require_project "$name"
      env_set "$(dir_project "$name")/.env" "NETBIRD_SETUP_KEY" ""
      if docker_ready; then
        msg "Recreating the environment without the NetBird client..."
        compose_run "$name" up -d --force-recreate
      fi
      ok "NetBird peer disabled for '$name' (Docker network isolation still applies)."
      ;;

    status)
      [[ $# -eq 1 ]] || die "$USAGE"
      local name=$1
      require_project "$name"
      require_docker
      local cont; cont=$(cont_name "$name")
      if ! docker exec "$cont" netbird status >/dev/null 2>&1; then
        die "NetBird client is not running in '$cont'. Enroll with: aienv netbird enroll $name <SETUP_KEY> --url <URL>"
      fi
      docker exec "$cont" netbird status || true
      ;;

    ip)
      [[ $# -eq 1 ]] || die "$USAGE"
      local name=$1
      require_project "$name"
      require_docker
      local cont; cont=$(cont_name "$name")
      [[ "$(cont_state "$cont")" == running ]] || die "Container '$cont' is not running."
      local ip
      ip=$(docker exec "$cont" netbird status 2>/dev/null \
           | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1) || ip=""
      if [[ -n "$ip" ]]; then
        ok "Peer '$name': $ip"
        echo "    From any mesh device: ssh dev@${ip}  ·  preview: http://${ip}:3000"
        echo "    MagicDNS name (if your NetBird domain is set up): http://${name}.<your-netbird-domain>:3000"
      else
        warn "No mesh IP yet: the client is not connected (see: aienv netbird logs $name)"
      fi
      ;;

    logs)
      [[ $# -eq 1 ]] || die "$USAGE"
      local name=$1
      require_project "$name"
      require_docker
      docker exec "$(cont_name "$name")" tail -50 /var/log/aienv.log 2>/dev/null || true
      ;;

    ssh)
      [[ $# -eq 1 ]] || die "$USAGE"
      local name=$1
      require_project "$name"
      require_docker
      [[ "$(cont_state "$(cont_name "$name")")" == running ]] || die "Container is not running."
      _ssh_targets "$name"
      echo "    Add one of these as a herdr remote machine to manage this environment from your own herdr window."
      ;;

    *) die "$USAGE" ;;
  esac
}

cmd_models() {
  local USAGE="Usage: aienv models <name> [model]
  aienv models <name>                  show the configured models (first = default)
  aienv models <name> qwen2.5-coder:7b make that model the default for pi"
  [[ $# -ge 1 ]] || die "$USAGE"
  local name=$1; shift
  require_project "$name"
  __AIENV_PROJECT=$name
  local proj; proj=$(dir_project "$name")
  local current; current=$(config_get AI_MODELS "qwen2.5-coder:3b qwen2.5-coder:7b")

  if [[ $# -eq 0 ]]; then
    ok "Models for '$name' (first one is the default):"
    local i=0 m
    for m in $current; do
      (( i == 0 )) && echo "  * $m   (default)" || echo "    $m"
      i=$((i + 1))
    done
    echo "    Change the default with: aienv models $name <model>"
    return 0
  fi

  local model=$1
  [[ "$model" =~ ^[A-Za-z0-9._:@/-]+$ ]] || die "Suspicious model name: '$model' (e.g. qwen2.5-coder:7b)"
  local rest="" m
  for m in $current; do
    [[ "$m" == "$model" ]] || rest+="${rest:+ }$m"
  done
  env_set "$proj/aienv.config" "AI_MODELS" "$model ${rest}"
  local tmp; tmp=$(mktemp)
  render_models_file "$proj" > "$tmp"
  write_over "$proj/pi-models.json" "$tmp"   # inode-preserving: safe while the container is running
  ok "Default model for '$name' is now: $model"
  echo "    pi reloads models.json on /model. Pull it on the AI server if missing:"
  echo "    ollama pull $model"
}
