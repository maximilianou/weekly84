#!/usr/bin/env bash
# __ provision.sh - installs the aienv stack INSIDE a sandbox __________________
# Copied to /tmp by 'aienv.sh new' and executed with:
#   sbx exec <name> bash /tmp/aienv-provision.sh
# Environment expected (baked in by 'aienv.sh new' with sbx -e flags):
#   AI_SERVER_URL, AI_MODELS, TZ. Sandbox users have sudo (Docker docs).
set -euo pipefail

log() { echo "[aienv] $*"; }

NODE_MIN=22

node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local v; v=$(node --version | sed 's/^v//' | cut -d. -f1)
  [[ $v -ge $NODE_MIN ]]
}

# 1. Node LTS (pi needs >= 22.19). The 'shell' base image may not ship it.
if node_ok; then
  log "node $(node --version) already present"
else
  log "installing Node ${NODE_MIN}.x from NodeSource (needs the deb.nodesource.com allow rule)"
  curl -fsSL https://deb.nodesource.com/setup_${NODE_MIN}.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

# 2. pi coding agent (official installer: pins all dependencies)
if command -v pi >/dev/null 2>&1; then
  log "pi already present: $(pi --version 2>/dev/null || echo present)"
else
  log "installing pi (pi.dev installer)"
  curl -fsSL https://pi.dev/install.sh | sh
fi

# 3. herdr - the runtime the coding agents live on (official installer)
if command -v herdr >/dev/null 2>&1; then
  log "herdr already present"
else
  log "installing herdr (herdr.dev installer)"
  curl -fsSL https://herdr.dev/install.sh | sh
fi

# 4. gh (handy for the per-project PAT workflow); optional, never fatal
if ! command -v gh >/dev/null 2>&1; then
  log "installing gh (best effort)"
  sudo apt-get update -qq && sudo apt-get install -y gh || log "gh install failed - install it manually with apt"
fi

# 5. pi model config: Ollama models exposed to pi. Same file the v3.1 toolkit
#    mounted at ~/.pi/agent/models.json (schema: pi.dev/schemas/models.schema.json).
MODELS_DIR="$HOME/.pi/agent"
mkdir -p "$MODELS_DIR"
json_models=""
for m in ${AI_MODELS:-}; do
  [[ -n $json_models ]] && json_models+=", "
  json_models+="{ \"id\": \"$m\", \"contextWindow\": 32768, \"maxTokens\": 8192 }"
done
cat > "$MODELS_DIR/models.json" <<EOF
{
  "\$schema": "https://pi.dev/schemas/models.schema.json",
  "providers": {
    "ollama": {
      "baseUrl": "${AI_SERVER_URL:-http://host.docker.internal:11434}/v1",
      "api": "openai-completions",
      "apiKey": "ollama",
      "models": [$json_models]
    }
  }
}
EOF
log "pi models written to $MODELS_DIR/models.json"

# 6. quick AI connectivity probe (non-fatal: the approval flow may still be pending)
if curl -fsS -m 5 "${AI_SERVER_URL:-http://host.docker.internal:11434}" >/dev/null 2>&1; then
  log "AI server reachable: ${AI_SERVER_URL}"
else
  log "AI server NOT reachable yet at ${AI_SERVER_URL}"
  log "  check:  aienv.sh policy stack <name>   (adds the localhost:<port> rule)"
  log "  probe:  curl ${AI_SERVER_URL}          (from inside the sandbox)"
fi

log "stack ready. Attach with: aienv.sh attach <name>  → then run 'pi' or 'herdr'"
