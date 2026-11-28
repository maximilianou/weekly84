#!/usr/bin/env bash
set -euo pipefail

OLLAMA_URL="http://192.168.122.1:11434"

# Configure UFW on VM
sudo apt-get update -y
sudo apt-get install -y ufw ca-certificates curl gnupg git
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw --force enable

# Install Docker Engine (official convenience script / repo) if missing
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "${USER}"
fi

# Install sbx CLI if missing
if ! command -v sbx >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/docker/sandbox-cli/main/install.sh | sh || true
fi

# Verify connectivity from VM to host Ollama
curl -fsS "${OLLAMA_URL}/api/tags" >/dev/null
echo "Ollama reachable at ${OLLAMA_URL}"
