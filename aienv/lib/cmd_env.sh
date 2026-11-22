#!/usr/bin/env bash
# ── lib/cmd_env.sh - image build, project creation, rendering, updates ────────

# build_image <node-image> - shared core for install/update
build_image() {
  local node_image=$1 uid gid
  uid=$(id -u); gid=$(id -g)
  msg "Building image aienv-base:latest (base: $node_image, uid $uid, gid $gid)..."
  docker build -t aienv-base:latest \
    --build-arg "NODE_IMAGE=$node_image" \
    --build-arg "UID=$uid" \
    --build-arg "GID=$gid" \
    "$AIENV_ROOT/templates/"
  printf '%s:%s %s\n' "$uid" "$gid" "$node_image" > "$AIENV_ROOT/.image-info"
  ok "Image ready."
}

cmd_install() {
  local node_image; node_image=$(toolkit_config_get NODE_IMAGE "node:lts-bookworm")
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node-image) node_image=${2:?}; shift 2 ;;
      *) die "Unknown option: '$1' (usage: aienv install [--node-image <image>])" ;;
    esac
  done
  require_docker
  build_image "$node_image"
  ok "Next: create an environment with: aienv create <name>"
}

# build the compose "ports:" block from the project's committable config
build_ports_block() {
  local proj=$1 cfg="$1/aienv.config"
  local bind pub_ssh pub_prev ssh_port ports hostports out="" l
  local lines=()
  bind=$(env_get "$cfg" PREVIEW_BIND);      [[ -n "$bind" ]]      || bind="127.0.0.1"
  pub_ssh=$(env_get "$cfg" PUBLISH_SSH);    [[ -n "$pub_ssh" ]]   || pub_ssh="1"
  pub_prev=$(env_get "$cfg" PUBLISH_PREVIEW); [[ -n "$pub_prev" ]] || pub_prev="1"
  ssh_port=$(env_get "$cfg" SSH_HOST_PORT)
  ports=$(env_get "$cfg" PREVIEW_PORTS)
  hostports=$(env_get "$cfg" PREVIEW_HOST_PORTS)

  if [[ "$pub_ssh" == "1" && -n "$ssh_port" ]]; then
    lines+=("      - \"${bind}:${ssh_port}:22\"")
  fi
  if [[ "$pub_prev" == "1" && -n "$ports" ]]; then
    local p_arr=($ports) h_arr=($hostports) i
    for i in "${!p_arr[@]}"; do
      [[ $i -lt ${#h_arr[@]} ]] || break
      lines+=("      - \"${bind}:${h_arr[$i]}:${p_arr[$i]}\"")
    done
  fi
  if [[ ${#lines[@]} -gt 0 ]]; then
    out="    ports:"
    for l in "${lines[@]}"; do out+=$'\n'"$l"; done
  fi
  printf '%s' "$out"
}

# render_compose <name> - regenerate docker-compose.yml from project config
render_compose() {
  local name=$1 proj; proj=$(dir_project "$name")
  __AIENV_PROJECT=$name
  local tz mem cpu pids ports_block
  tz=$(config_get TZ "UTC")
  mem=$(config_get MEM_LIMIT "4g")
  cpu=$(config_get CPU_LIMIT "2.0")
  pids=$(config_get PIDS_LIMIT "512")
  ports_block=$(build_ports_block "$proj")
  render_tpl "$AIENV_ROOT/templates/compose.yml.tpl" "$proj/docker-compose.yml" \
    "NAME" "$name" "TZ" "$tz" "PIDS_LIMIT" "$pids" "MEM_LIMIT" "$mem" "CPU_LIMIT" "$cpu" \
    "PORTS" "$ports_block"
}

cmd_render() {
  [[ $# -eq 1 ]] || die "Usage: aienv render <name>"
  local name=$1 proj; proj=$(dir_project "$name")
  require_project "$name"
  render_compose "$name"
  __AIENV_PROJECT=$name
  render_models_file "$proj" > "$proj/pi-models.json"
  ok "Re-rendered docker-compose.yml and pi-models.json for '$name'."
  warn "Apply the changes to a running environment: aienv stop $name && aienv start $name"
}

cmd_create() {
  local USAGE="Usage: aienv create <name> [options]
  <name>                   project name (lowercase, e.g. weekly85)
  --repo owner/repo|URL    GitHub repository to clone (default: local git init)
  --create-repo            create the repo on GitHub (private) if missing (needs gh auth on this host)
  --token PAT              fine-grained GitHub PAT for this project (or edit <project>/.env later)
  --setup-key KEY          NetBird setup key for this project's mesh peer
  --management-url URL     your self-hosted NetBird management URL
  --git-user NAME          commit name (default: host git config)
  --git-email EMAIL        commit email (default: host git config)
  --no-start               write files only, skip image build and container start"

  [[ $# -ge 1 ]] || die "$USAGE"
  local name=$1; shift

  local repo="" create_repo=0 token="" setup_key="" mgmt_url="" git_user="" git_email="" do_start=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)           repo=${2:?}; shift 2 ;;
      --create-repo)    create_repo=1; shift ;;
      --token)          token=${2:?}; shift 2 ;;
      --setup-key)      setup_key=${2:?}; shift 2 ;;
      --management-url) mgmt_url=${2:?}; shift 2 ;;
      --git-user)       git_user=${2:?}; shift 2 ;;
      --git-email)      git_email=${2:?}; shift 2 ;;
      --no-start)       do_start=0; shift ;;
      *)                die "Unknown option: '$1'\n\n$USAGE" ;;
    esac
  done

  name_valid "$name" || die "Invalid name: '$name' - lowercase letters, digits and dashes only (max 39 chars)."
  local proj; proj=$(dir_project "$name")
  [[ -e "$proj" ]] && die "Already exists: $proj - pick another name or remove it with: aienv destroy $name"

  msg "Creating project '$name' in $proj"
  mkdir -p "$proj/workspace" "$proj/netbird-state"

  # ── repository ────────────────────────────────────────────────────────────
  local url="" slug="$name" cloned=0
  if [[ -n "$repo" ]]; then
    case "$repo" in
      https://github.com/*|git@github.com:*|ssh://git@github.com:*)
        url="$repo"; slug="${repo##*/}"; slug="${slug%.git}" ;;
      */*) url="https://github.com/$repo.git"; slug="$repo" ;;
      *) die "--repo expects 'owner/repo' or a full GitHub URL." ;;
    esac
  fi
  if [[ -n "$url" ]]; then
    if timeout 15 git ls-remote "$url" HEAD >/dev/null 2>&1; then
      msg "Cloning $url ..."
      git clone "$url" "$proj/workspace"
      cloned=1
    elif (( create_repo )) && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      msg "Repository not reachable: creating it on GitHub (private) and cloning..."
      gh repo create "$slug" --private --clone "$proj/workspace"
      cloned=1
    else
      warn "Repository not reachable (or gh not authenticated): doing a local 'git init'."
      warn "Attach a remote later with: git -C $proj/workspace remote add origin <URL>"
    fi
  fi
  if (( ! cloned )); then
    git -C "$proj/workspace" init -q -b main
  fi

  # ── resolve configuration (toolkit layer) ─────────────────────────────────
  [[ -n "$token" ]]     || token=$(toolkit_config_get GITHUB_TOKEN "")
  [[ -n "$setup_key" ]] || setup_key=$(toolkit_config_get NETBIRD_SETUP_KEY "")
  [[ -n "$mgmt_url" ]]  || mgmt_url=$(toolkit_config_get NB_MANAGEMENT_URL "")
  local ssh_key ai_url models preview_ports tz mem cpu pids
  ssh_key=$(toolkit_config_get SSH_PUBLIC_KEY "")
  ai_url=$(toolkit_config_get AI_SERVER_URL "http://desk01.netbird.selfhosted:11434")
  models=$(toolkit_config_get AI_MODELS "qwen2.5-coder:3b qwen2.5-coder:7b")
  preview_ports=$(toolkit_config_get PREVIEW_PORTS "3000 5173 8080")
  tz=$(toolkit_config_get TZ "UTC")
  mem=$(toolkit_config_get MEM_LIMIT "4g")
  cpu=$(toolkit_config_get CPU_LIMIT "2.0")
  pids=$(toolkit_config_get PIDS_LIMIT "512")
  [[ -n "$git_user" ]]  || git_user="$(git config --global user.name 2>/dev/null || true)"
  [[ -n "$git_email" ]] || git_email="$(git config --global user.email 2>/dev/null || true)"
  [[ -n "$git_user" ]]  || git_user="Your Name"
  [[ -n "$git_email" ]] || git_email="you@example.com"

  # ── pick stable host ports (ssh + preview) ────────────────────────────────
  local base ssh_port next hp hostports_list=""
  base=$(name_port_base "$name")
  ssh_port=$(pick_free_port "$base")
  next=$((ssh_port + 1))
  local p
  for p in $preview_ports; do
    hp=$(pick_free_port "$next")
    hostports_list+="${hostports_list:+ }$hp"
    next=$((hp + 1))
  done

  # ── write project files ───────────────────────────────────────────────────
  cat > "$proj/.env" <<EOF
# Private configuration for project $name. NEVER commit this file.
GITHUB_TOKEN=${token:-PASTE_YOUR_TOKEN_HERE}
NETBIRD_SETUP_KEY=${setup_key}
NB_MANAGEMENT_URL=${mgmt_url}
AI_SERVER_URL=${ai_url}
SSH_PUBLIC_KEY=${ssh_key}
EOF
  chmod 600 "$proj/.env"

  cat > "$proj/aienv.config" <<EOF
# Project settings for $name (safe to commit; keep .env private).
REPO=${repo}
AI_MODELS=${models}
PREVIEW_PORTS=${preview_ports}
PREVIEW_HOST_PORTS=${hostports_list}
SSH_HOST_PORT=${ssh_port}
PUBLISH_SSH=1
PUBLISH_PREVIEW=1
PREVIEW_BIND=127.0.0.1
MEM_LIMIT=${mem}
CPU_LIMIT=${cpu}
PIDS_LIMIT=${pids}
TZ=${tz}
EOF

  render_tpl "$AIENV_ROOT/templates/gitconfig.tpl" "$proj/gitconfig" \
    "GIT_USER" "$git_user" "GIT_EMAIL" "$git_email"

  render_compose "$name"
  __AIENV_PROJECT=$name
  render_models_file "$proj" > "$proj/pi-models.json"

  local repo_desc="$slug"; (( cloned )) || repo_desc="(local init - no remote yet)"
  if [[ ! -f "$proj/workspace/AGENTS.md" ]]; then
    render_tpl "$AIENV_ROOT/templates/AGENTS.md.tpl" "$proj/workspace/AGENTS.md" \
      "NAME" "$name" "REPO" "$repo_desc"
  fi

  # ── image + start ─────────────────────────────────────────────────────────
  if (( do_start )); then
    require_docker
    if ! docker image inspect aienv-base:latest >/dev/null 2>&1; then
      msg "Image aienv-base missing: building it (10-15 min the first time)..."
      build_image "$(toolkit_config_get NODE_IMAGE "node:lts-bookworm")"
    fi
    compose_run "$name" up -d
    ok "Environment '$name' started."
  else
    warn "--no-start: files are ready. When you want: aienv install (once), then aienv start $name"
  fi

  # ── summary ───────────────────────────────────────────────────────────────
  echo
  ok "Project '$name' is ready:"
  echo "    folder    : $proj"
  if (( cloned )); then
    echo "    workspace : $proj/workspace (cloned from $url)"
  else
    echo "    workspace : $proj/workspace (local git init)"
  fi
  echo "    preview   : http://localhost:${hostports_list%% *} (+ mapped ports below) once a dev server runs on 0.0.0.0"
  echo "    ssh       : ssh dev@localhost -p ${ssh_port}   (or via NetBird peer name after enrollment)"
  [[ -n "$token" ]]     || echo "    ⚠ token   : paste the fine-grained PAT into $proj/.env (GITHUB_TOKEN)"
  [[ -n "$setup_key" ]] || echo "    ⚠ netbird : aienv netbird enroll $name <SETUP_KEY> --url https://your-management-url"
  echo
  echo "Next steps:"
  echo "    aienv enter $name        # open herdr and start working (or aienv shell $name)"
  echo "    aienv pi $name           # run pi directly in the project"
  echo "    aienv status             # overview of all environments"
}

cmd_start() {
  [[ $# -eq 1 ]] || die "Usage: aienv start <name>"
  local name=$1
  require_project "$name"
  require_docker
  require_image
  if ! token_set "$name"; then
    warn "GitHub PAT missing: git/gh will fail until you set GITHUB_TOKEN in $(dir_project "$name")/.env"
  fi
  __AIENV_PROJECT=$name
  if [[ "$(config_get NETBIRD_SETUP_KEY "")" != "" && "$(config_get NB_MANAGEMENT_URL "")" == "" ]]; then
    warn "A NetBird setup key is set but NB_MANAGEMENT_URL is empty: the NetBird client will stay off."
    warn "Fix with: aienv netbird enroll $name <SETUP_KEY> --url https://your-management-url"
  fi
  compose_run "$name" up -d
  ok "Environment '$name' is up. Enter it with: aienv enter $name"
}

cmd_stop() {
  [[ $# -eq 1 ]] || die "Usage: aienv stop <name>"
  local name=$1
  require_project "$name"
  require_docker
  compose_run "$name" stop
  ok "Environment '$name' stopped. Code is safe in $(dir_project "$name")/workspace"
  warn "Note: herdr sessions do not survive a container stop - the code does."
}

cmd_update() {
  require_docker
  local node_image; node_image=$(toolkit_config_get NODE_IMAGE "node:lts-bookworm")
  msg "Updating everything to the latest stable versions: base image ($node_image), apt packages, pi, herdr, NetBird client."
  build_image "$node_image"
  local d name rebuilt_any=0
  for d in "$AIENV_PROJECTS"/*/; do
    [[ -f "$d/docker-compose.yml" ]] || continue
    name=$(basename "$d")
    if [[ "$(cont_state "$(cont_name "$name")")" == running ]]; then
      msg "Recreating running environment '$name' with the new image..."
      compose_run "$name" up -d
      rebuilt_any=1
    fi
  done
  if (( rebuilt_any )); then
    warn "Recreated environments lost their herdr sessions (code is safe; agents were stopped)."
  fi
  ok "Update complete. Stopped environments will use the new image at their next 'aienv start'."
}

cmd_destroy() {
  [[ $# -ge 1 ]] || die "Usage: aienv destroy <name> [--all]"
  local name=$1; shift
  local wipe_all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) wipe_all=1; shift ;;
      *)     die "Unknown option: '$1'" ;;
    esac
  done
  require_project "$name"
  local proj; proj=$(dir_project "$name")

  if docker_ready; then
    msg "Removing containers and network of project '$name'..."
    compose_run "$name" down -v --remove-orphans 2>/dev/null \
      || warn "Nothing to remove (the environment was never started)."
  else
    warn "Docker not available: skipping container removal (remove them manually if any exist)."
  fi

  if (( wipe_all )); then
    echo "⚠ You are about to DELETE the whole project '$name':"
    echo "    $proj (including workspace - unpushed work will be lost)."
    echo "    Other projects and the GitHub repository stay untouched."
    local confirm
    read -r -p "Type the project name ('$name') to confirm: " confirm
    [[ "$confirm" == "$name" ]] || die "Confirmation does not match - aborted, nothing was deleted."
    rm -rf "$proj"
    ok "Project '$name' fully removed."
  else
    ok "Containers and network removed. Code remains in $proj/workspace"
    echo "    To also delete the folder: aienv destroy $name --all"
  fi
}
