#!/usr/bin/env bash
set -euo pipefail

# Official Ollama systemd override to listen on all interfaces (0.0.0.0:11434)
sudo mkdir -p /etc/systemd/system/ollama.service.d
cat <<'EOF' | sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EOF

# Configure UFW to allow Ollama port 11434 ONLY from KVM subnet 192.168.122.0/24
sudo apt-get update -y
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on virbr0 to any port 11434 proto tcp || sudo ufw allow from 192.168.122.0/24 to any port 11434 proto tcp
sudo ufw --force enable

# Reload systemd, restart Ollama, and verify model presence
sudo systemctl daemon-reload
sudo systemctl restart ollama
sudo systemctl is-active --quiet ollama
ollama list | grep -i "inkling-2-mini" || {
  echo "WARNING: inkling-2-mini not found in ollama list. Pull or verify model name."
}
