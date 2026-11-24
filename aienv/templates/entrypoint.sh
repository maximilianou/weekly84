#!/usr/bin/env bash
# aienv entrypoint: sshd + NetBird client (MagicDNS inside the container) and
# then drop to the dev user. Secrets (NETBIRD_SETUP_KEY, SSH_PUBLIC_KEY) are
# unset before the work session starts, so agents never see them.
set -uo pipefail

LOG=/var/log/aienv.log
: > "$LOG"   # fresh log per container start

# 1. workspace ownership (bind mount)
mkdir -p /workspace && chown dev:dev /workspace 2>/dev/null || true
echo "aienv: workspace ready at /workspace"

# 2. inject the SSH public key and start sshd (key-only auth)
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
  install -d -m 700 -o dev -g dev /home/dev/.ssh
  printf '%s\n' "$SSH_PUBLIC_KEY" > /home/dev/.ssh/authorized_keys
  chown dev:dev /home/dev/.ssh/authorized_keys
  chmod 600 /home/dev/.ssh/authorized_keys
fi
/usr/sbin/sshd
echo "aienv: sshd started (key-only auth)"

# 3. NetBird client: daemon (netbird service run) + enrollment (netbird up)
if [[ -n "${NETBIRD_SETUP_KEY:-}" ]]; then
  if [[ -z "${NB_MANAGEMENT_URL:-}" ]]; then
    echo "aienv: NETBIRD_SETUP_KEY set but NB_MANAGEMENT_URL empty - skipping NetBird."
    echo "aienv: fix with 'aienv netbird enroll <name> <KEY> --url <management-url>'"
  else
    echo "aienv: starting NetBird (peer hostname: $(hostname -s)) - details in /var/log/aienv.log"
    netbird service run >>"$LOG" 2>&1 &
    for _ in $(seq 1 30); do
      netbird status --check live >/dev/null 2>&1 && break
      sleep 1
    done
    ( netbird up --setup-key "$NETBIRD_SETUP_KEY" \
        --management-url "$NB_MANAGEMENT_URL" \
        --hostname "$(hostname -s)" ) >>"$LOG" 2>&1 &
  fi
else
  echo "aienv: no NETBIRD_SETUP_KEY set - running without the mesh (Docker isolation only)"
fi

# 4. drop secrets from the environment, then run the work session as dev
unset NETBIRD_SETUP_KEY NB_MANAGEMENT_URL SSH_PUBLIC_KEY
exec gosu dev "$@"
