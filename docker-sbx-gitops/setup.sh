#!/usr/bin/env bash
# =============================================================================
# ./setup.sh -- one-time HOST bootstrap for the devstack Docker Sandbox
#
#  1. checks/installs the sbx CLI (Docker Sandboxes)
#  2. checks sbx login (Docker OAuth)
#  3. prepares host-local AI: Ollama reachable at OLLAMA_BIND_HOST + model pull
#  4. allows sandbox -> host AI traffic in the network policy
#  5. Linux only: verifies KVM (required for local sandboxes)
#
# Then run ./sbx.sh up to instantiate the sandbox.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [ ! -f "$ROOT/etc.env" ]; then
  cp "$ROOT/etc.env.example" "$ROOT/etc.env"
  echo "- created etc.env from etc.env.example"
fi
# shellcheck disable=SC1091
. "$ROOT/etc.env"

ok()   { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

OS="$(uname -s)"

# -- 1. sbx CLI ----------------------------------------------------------------
# Docs: https://docs.docker.com/ai/sandboxes/install/
if command -v sbx >/dev/null 2>&1; then
  ok "sbx CLI found: $(sbx version 2>/dev/null | head -n1 || echo 'version n/a')"
else
  warn "sbx CLI not found -- install it with ONE of:"
  case "$OS" in
    Darwin)
      echo "    brew trust docker/tap && brew install docker/tap/sbx" ;;
    Linux)
      echo "    curl -fsSL https://get.docker.com | sudo SBX=1 sh        # Docker Engine + sbx"
      echo "  or (sbx only, no host Docker Engine):"
      echo "    curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh && sudo apt install docker-sbx"
      echo "  Requirements: Ubuntu 24.04+, KVM enabled (user in the 'kvm' group)." ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "    winget install -h Docker.sbx" ;;
    *)
      echo "    see https://docs.docker.com/ai/sandboxes/install/" ;;
  esac
  die "install sbx, then re-run ./setup.sh"
fi

# -- 2. sbx login (required) --------------------------------------------------
if sbx ls >/dev/null 2>&1; then
  ok "sbx authenticated"
else
  warn "not signed in -- run: sbx login   (opens browser for Docker OAuth)"
  die "run 'sbx login', then re-run ./setup.sh"
fi

# -- 3. Linux KVM check (local sandboxes need it; cloud does not) -------------
# The module name differs by CPU vendor: kvm_amd on AMD, kvm_intel on Intel,
# kvm on Intel/ARM as shared base. So do NOT grep for the generic 'kvm' alone
# and do not trust grep -q silence: enumerate every kvm* module and use
# /dev/kvm as the authoritative, vendor-independent signal.
if [ "$OS" = "Linux" ]; then
  _kvm_mods="$(lsmod 2>/dev/null | awk '$1 ~ /^kvm/ {printf "%s ", $1}')"
  if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ok "KVM available (/dev/kvm readable/writable by you; modules: ${_kvm_mods:-none})"
  elif [ -n "${_kvm_mods// }" ]; then
    warn "KVM modules ARE loaded (${_kvm_mods}) but /dev/kvm is missing or not accessible by your user:"
    echo "    ls -l /dev/kvm               # owner should be root:kvm, mode 660"
    echo "    sudo usermod -aG kvm \$USER   # then log out/in (or: newgrp kvm)"
    echo "  (or use cloud sandboxes, which do not need KVM)"
  else
    warn "KVM not available -- no kvm* module loaded and no /dev/kvm device"
    echo "    Debian/Ubuntu:  sudo modprobe kvm_amd    # AMD (use kvm_intel on Intel)"
    echo "    sudo usermod -aG kvm \$USER   # then log out/in"
    echo "  (or use cloud sandboxes, which do not need KVM)"
  fi
fi

# -- 4. Host-local AI: Ollama -------------------------------------------------
ai_host_port="${AI_OLLAMA_URL##*:}"
ai_host_port="${ai_host_port%%/*}"

if [ "$AI_PROVIDER" = "ollama" ]; then
  if command -v ollama >/dev/null 2>&1; then
    ok "ollama found: $(ollama --version 2>/dev/null | head -n1 || echo 'version n/a')"
    if curl -fsS -m 3 "http://127.0.0.1:$ai_host_port/api/tags" >/dev/null 2>&1; then
      ok "ollama is answering on 127.0.0.1:$ai_host_port"
    else
      warn "ollama is not reachable on 127.0.0.1:$ai_host_port -- start it:"
      echo "    ollama serve   # or: sudo systemctl start ollama"
    fi
    # The sandbox reaches the host as a container; Ollama must not bind only
    # to 127.0.0.1. Documented fix (no silent systemd edits here):
    warn "make sure the daemon binds $OLLAMA_BIND_HOST so the sandbox can connect:"
    echo "    sudo systemctl edit ollama   -> add:"
    echo "        [Service]"
    echo "        Environment=\"OLLAMA_HOST=$OLLAMA_BIND_HOST\""
    echo "    sudo systemctl restart ollama"
    if ollama list 2>/dev/null | grep -q "$AI_OLLAMA_MODEL"; then
      ok "model present: $AI_OLLAMA_MODEL"
    else
      warn "model '$AI_OLLAMA_MODEL' not found -- pulling..."
      ollama pull "$AI_OLLAMA_MODEL" || warn "pull failed; run 'ollama pull $AI_OLLAMA_MODEL' manually"
    fi
  else
    warn "ollama not found -- install from https://ollama.com/download, then re-run"
  fi
elif [ "$AI_PROVIDER" = "model-runner" ]; then
  ok "AI_PROVIDER=model-runner -- the sandbox will use $AI_MODEL_RUNNER_URL"
  warn "verify the Docker Model Runner is enabled on your host"
else
  die "AI_PROVIDER must be 'ollama' or 'model-runner' (got: $AI_PROVIDER)"
fi

# -- 5. Network policy: allow sandbox -> host AI -------------------------------
# The kit already declares these in kit/devstack/devstack.yaml; this makes the
# host-side policy explicit for balanced/deny-all presets.
# Docs: https://docs.docker.com/ai/sandboxes/configuration/local/ (governance)
if [ "$AI_PROVIDER" = "ollama" ]; then
  if sbx policy allow network "host.docker.internal:$ai_host_port" >/dev/null 2>&1; then
    ok "policy: sandbox -> host.docker.internal:$ai_host_port allowed"
  else
    warn "could not set policy automatically -- run manually:"
    echo "    sbx policy allow network 'host.docker.internal:$ai_host_port'"
  fi
fi
if sbx policy allow network "model-runner.docker.internal" >/dev/null 2>&1; then
  ok "policy: sandbox -> model-runner.docker.internal allowed"
else
  warn "run manually: sbx policy allow network 'model-runner.docker.internal'"
fi

# -- Done ---------------------------------------------------------------------
ok "host is ready. Next:"
echo "    ./sbx.sh plan     # review the apply plan"
echo "    ./sbx.sh up       # create + bootstrap the sandbox (first run builds the kit)"
echo "    ./sbx.sh url      # component URLs"
echo "    ./sbx.sh shell    # terminal inside the sandbox (pi / herdr / openspec)"
