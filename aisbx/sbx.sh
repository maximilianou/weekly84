#!/usr/bin/env bash
# __ sbx.sh - stable entrypoint to Docker's OFFICIAL 'sbx' CLI _________________
# Regola 2 (Msg 9): the bare name 'sbx' stays reserved for Docker's binary;
# every script WE write carries .sh. This wrapper never shadows it - it just
# forwards to it after checking it exists, so muscle memory and docs keep one
# obvious way to reach the real CLI.
set -euo pipefail

if ! command -v sbx >/dev/null 2>&1; then
  echo "sbx.sh: Docker's official 'sbx' CLI is not in PATH." >&2
  echo "  Install (Ubuntu 24.04+): curl -fsSL https://get.docker.com | sudo SBX=1 sh" >&2
  echo "  Docs: https://docs.docker.com/ai/sandboxes/install/" >&2
  exit 127
fi

exec sbx "$@"
