#!/usr/bin/env bash
set -euo pipefail

KIT_DIR="/home/dev01/projects/weekly84/dev-ai-kit-v12/sbx-pi-kit"
SANDBOX_NAME="weekly85"
OLLAMA_URL="http://192.168.122.1:11434"

# 1. Configure UFW on Ubuntu 26 VM
sudo apt-get update -y
sudo apt-get install -y ufw ca-certificates curl gnupg git
# sudo ufw default deny incoming
# sudo ufw default allow outgoing
# sudo ufw allow 22/tcp
# sudo ufw --force enable

# 2. Install Docker & sbx CLI if missing
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "${USER}"
fi

if ! command -v sbx >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/docker/sandbox-cli/main/install.sh | sh
fi

# 3. Verify connectivity to host Ollama
curl -fsS "${OLLAMA_URL}/api/tags" >/dev/null

# 4. Recreate sandbox declaratively from sbxenv.yaml
cd "${KIT_DIR}"
set -a && source ./.env && set +a
sbx env rm --force >/dev/null 2>&1 || true
sbx env create --force

# 5. Allow required egress domains in sbx network policy (prevents HTTP 403)
ALLOWED_HOSTS=(
  "192.168.122.1:11434"
  "herdr.dev"
  "releases.herdr.dev"
  "github.com"
  "api.github.com"
  "objects.githubusercontent.com"
  "raw.githubusercontent.com"
  "registry.npmjs.org"
  "deb.debian.org"
  "security.debian.org"
  "archive.ubuntu.com"
  "security.ubuntu.com"
)

for host in "${ALLOWED_HOSTS[@]}"; do
  sbx policy allow network --sandbox "${SANDBOX_NAME}" "${host}" >/dev/null 2>&1 || \
  sbx policy allow network --sandbox "${SANDBOX_NAME}" --resource "${host}" >/dev/null 2>&1 || true
done

# 6. Run internal sandbox bootstrap script (installs herdr server, pi models.json, openspec, gh, 5 skills)
sbx env exec -- bash -lc "chmod +x ./scripts/sbx-bootstrap.sh && ./scripts/sbx-bootstrap.sh"

echo "VM and Sandbox '${SANDBOX_NAME}' ready. Enter with: sbx env exec -- bash -l"
