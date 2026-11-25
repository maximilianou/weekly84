# docker-sbx-gitops

GitOps template project that instantiates a [Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/usage/)
development environment **declaratively from committed config files**.

Local AI runs **on the host with Ollama**; everything else lives **inside the
sandbox**, created from a custom kit:

- **pi.dev** -- coding agent (driven by host Ollama)
- **herdr.dev** -- terminal multiplexer that owns agent terminals
- **openspec** -- spec-driven development CLI
- **TypeScript API** -- Express + pg, dev server (tsx watch)
- **TypeScript React frontend** -- Vite dev server, proxies `/api` to the API
- **PostgreSQL** (dev container) + **Adminer** (web admin for Postgres)

All components communicate: `web -> api -> postgres`, `adminer -> postgres`
(internal docker network), `pi -> host Ollama`.

## Architecture

```
HOST                                                     SANDBOX (devstack)
-----------------------------                          -------------------------------------------
 Ollama :11434  <-------- host.docker.internal ------>  pi  (models.json -> Ollama)
      ^                                                        | owns terminals
   bind 0.0.0.0                                                v
   (setup.sh)                                            herdr  - panes: pi / shell / logs
                                                               |
  browser :5173 ---------------------------------------->  web (Vite/React) --/api-->  api
  curl :4000 ------------------------------------------>  api (Express/tsx) ---------> postgres
  browser :8081 --------------------------------------->  adminer-dev ----devnet----> pg-dev
  psql :5432 ------------------------------------------>  postgres (published on loopback)

  sbx runtime: outbound TCP policy (kit allow-list) | ports published by sbxenv.yaml
```

## File tree

| File | Role |
|---|---|
| `etc.env.example` | **Every variable**, documented -- the committed template |
| `etc.env` | Local working values (gitignored; created by the scripts if missing) |
| `sbxenv.yaml` | Declarative sandbox definition (schemaVersion 1): agent, kits, workspace, env fallbacks, published ports. **Must stay at the repo root** -- sbx resolves its relative paths (kits, workspace) from the env file's own directory |
| `kit/devstack/devstack.yaml` | Kit descriptor (schemaVersion 3): workload + network policy + agent context. **First line must be `# syntax=docker/sandbox-kit:3`** -- buildkit receives this file as the build definition |
| `kit/devstack/devstack.dockerfile` | Kit image: Node 22, pi, openspec, herdr, psql, Docker-in-sandbox base. **Ordinary Dockerfile** - NO `# syntax=` directive (that belongs only on line 1 of the descriptor yaml) |
| `kit/devstack/files/AGENTS.md` | In-sandbox guide injected to the agent |
| `kit/devstack/files/.devstack_env` | Env loader sourced by every sandbox shell (BASH_ENV) |
| `kit/devstack/files/pi-models.template.json` | pi <-> Ollama provider config, rendered by bootstrap |
| `kit/devstack/files/bootstrap/10-devstack.sh` | Idempotent bootstrap: postgres, adminer, api, web, pi config, health checks |
| `workspaces/api`, `workspaces/web` | The two dev workspaces (mounted as the sandbox's primary workspace) |
| `policy/README.md` | Network-rule rationale + `sbx policy` commands |
| `setup.sh` | One-time **host** bootstrap (sbx install check, login, Ollama, policy) |
| `sbx.sh` | Day-2 wrapper: check/plan/up/shell/exec/logs/ports/url/ai/daemonlog/db/down/rm/new |

## Quickstart

```bash
cp etc.env.example etc.env       # adjust values (ports, model, credentials)
./setup.sh                       # host: sbx + login + Ollama + policy
./sbx.sh check                   # verify every path/port sbx will resolve
./sbx.sh plan                    # review what will be created
./sbx.sh up                      # create sandbox, sync env, bootstrap, health-check
./sbx.sh url                     # open the component URLs
./sbx.sh shell                   # terminal in the sandbox -> run: herdr  /  pi
```

First `up` builds the kit image (Node 26 + tools); later runs reuse it. The
bootstrap is idempotent -- re-run `./sbx.sh up` after host reboots or to apply
new `etc.env` values.

## Project name: one template, many weekly projects

ONE name (`SBX_NAME` in etc.env, or `--name` per invocation) drives every
per-project resource:

| Resource | Value for name `weekly85` |
|---|---|
| Sandbox (`sbx ls`) | `weekly85` |
| Postgres volume | `weekly85-pgdata` |
| Internal docker network | `weekly85-net` |
| Default GitHub repo | `<GITHUB_OWNER>/weekly85` |

```bash
./sbx.sh new weekly85                 # copy the template and name it
cd ../../weekly85                     # or: ./sbx.sh new weekly85 ~/projects/weekly85
# put the fine-grained GitHub token in etc.env (GITHUB_TOKEN), then:
./setup.sh && ./sbx.sh up
```

`./sbx.sh up --name weekly86` overrides the name for that run on an existing
checkout (`check`, `plan`, `up`, `rm`, `reset` accept `--name`). `PGDATA_VOLUME`
and `SBX_NET_NAME` are derived from the name, not set by hand. The kit
directory stays `kit/devstack`: it is shared tooling (Node, pi, herdr,
openspec), not project state, and its image is built once and reused by every
project.

## GitHub fine-grained token (push exactly one repo)

The sandbox authenticates with a **fine-grained PAT scoped to exactly one
repository**, so the agent can push the project and nothing else:

1. Open https://github.com/settings/personal-access-tokens/new
2. Repository access: **Only select repositories** -> `<owner>/<project>`
   (e.g. `maximilianou/weekly85`).
3. Permissions: **Contents: Read and write** (plus **Pull requests: Read and
   write** if the agent should open PRs); Metadata is granted automatically.
4. Put `GITHUB_OWNER`, `GITHUB_TOKEN` (and optionally `GIT_USER_NAME` /
   `GIT_USER_EMAIL`) in `etc.env` -- never commit them; etc.env is gitignored.

`./setup.sh` verifies the token: it must reach the repo **with push
permission** and must not be scoped to many other repos. Inside the sandbox,
the bootstrap installs a git credential helper that reads `GITHUB_TOKEN` from
the environment at push time (never written to a file there), sets the git
identity, and marks the mounted workspace safe for git. `github.com` and
`api.github.com` are already in the kit network allow-list.

## GitOps workflow

1. **Config is code**: change `etc.env.example` / `sbxenv.yaml` /
   `kit/devstack/*` in a pull request. `./sbx.sh plan` previews the apply plan
   (`sbx env plan`) before anything is created.
2. **Apply**: `./sbx.sh up` = `sbx env create` -> sync `etc.env` into
   `/etc/sandbox-persistent.sh` -> run the idempotent bootstrap -> health checks.
3. **Policy**: when the TUI network panel reveals a needed host, codify it into
   `kit/devstack/devstack.yaml` (`config.runtime.allow`) via PR.
4. **Destruction**: `./sbx.sh rm` (`sbx env rm`). The Postgres named volume
   survives unless you remove it (`./sbx.sh exec docker volume rm devstack-pgdata`).

## Variable reference (etc.env)

| Group | Variables |
|---|---|
| Sandbox identity | `SBX_NAME`, `SBX_ENV_FILE` |
| Local AI (host) | `AI_PROVIDER` (ollama\|model-runner), `AI_OLLAMA_URL`, `AI_OLLAMA_MODEL`, `AI_MODEL_RUNNER_URL`, `OLLAMA_BIND_HOST` |
| Postgres dev | `POSTGRES_IMAGE`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_HOST`, `PGDATA_VOLUME`, `PG_PORT`, optional `DATABASE_URL` |
| Postgres admin | `ADMINER_IMAGE`, `ADMINER_PORT`, `ADMINER_DEFAULT_SERVER` |
| TS API | `API_PORT`, `NODE_ENV` |
| React web | `WEB_PORT`, `VITE_API_BASE` |
| Internal network / volume | `SBX_NET_NAME`, `PGDATA_VOLUME` -- derived from the project name (`<name>-net`, `<name>-pgdata`) |
| GitHub | `GITHUB_OWNER`, `GITHUB_REPO` (default: project name), `GITHUB_TOKEN`, `GIT_USER_NAME`, `GIT_USER_EMAIL` |

Ports published to the host are declared in `sbxenv.yaml` (`ports:`,
loopback by default) and must match `PG_PORT` / `API_PORT` / `WEB_PORT` /
`ADMINER_PORT` -- `./sbx.sh check` verifies the sync. `./sbx.sh up` syncs every
`etc.env` value into the sandbox (each shell sources it), so `etc.env` is
authoritative at runtime.

## Communication map

| From -> To | Path |
|---|---|
| web -> api | Vite proxy `/api` -> `127.0.0.1:$API_PORT` (inside sandbox) |
| api -> postgres | `DATABASE_URL` -> `127.0.0.1:$PG_PORT` (pg-dev loopback publish); verified by `GET /api/health` |
| adminer -> postgres | internal docker network DNS `$POSTGRES_HOST:5432` |
| pi -> Ollama | `AI_OLLAMA_URL` (`host.docker.internal:11434`) via `~/.pi/agent/models.json`; switch with `AI_PROVIDER=model-runner` |
| you -> everything | host ports from `sbxenv.yaml`; `./sbx.sh shell` / `exec` for the rest |

## Troubleshooting

- `error: resolve kits: kit path .../env/kit/devstack does not exist` -- every
  relative path in `sbxenv.yaml` (kits, workspace, mounts) is resolved from the
  env file's **own directory**, not from where you run sbx. `sbxenv.yaml` must
  sit at the repo root, next to `kit/` and `workspaces/`. Run `./sbx.sh check`
  to see every path sbx will resolve. If a failed run left an empty
  `env/workspaces` directory behind (sbx pre-creates bind-mount sources), it is
  safe to delete.
- **KVM on AMD hosts**: the loaded module is `kvm_amd` (Intel: `kvm_intel`), so
  `grep '^kvm'`-style checks can mislead. `setup.sh` checks the `/dev/kvm`
  device (vendor-independent) and enumerates all `kvm*` modules instead. If
  modules are loaded but `/dev/kvm` is not accessible:
  `sudo usermod -aG kvm $USER`, then log out/in (or `newgrp kvm`).
- `unknown instruction: schemaVersion:` (any `dockerfile parse error`) while the
  kit builds: buildkit received the descriptor (`devstack.yaml`) as the build
  definition but the sandbox-kit frontend was never activated. The descriptor
  must **start** with `# syntax=docker/sandbox-kit:3` (very first line, before
  any comment banner).
- `content recipe ... names the kit frontend in its syntax directive; the recipe
  is an ordinary Dockerfile`: the directive was ALSO written into the companion
  `devstack.dockerfile`. It belongs ONLY in the descriptor yaml - the recipe
  must be an ordinary Dockerfile. `./sbx.sh check` verifies both sides.
- `failed to run sandbox container` (right after "image ready") is a generic
  wrapper: the real cause is in the sbx daemon log
  `~/.local/state/sandboxes/sandboxes/sandboxd/daemon.log`
  (`./sbx.sh daemonlog`, or `sbx diagnose`). On Debian-family hosts the
  recurring causes (see docker/sbx-releases issue 444) are, in order:
  `/dev/loop-control` permissions (add yourself to the `disk` group next to
  `kvm`, then re-login), `/usr/sbin` missing from PATH (the sbx daemon looks
  up mkfs.erofs/losetup/mount there: `export PATH="$PATH:/usr/sbin"` then
  `sbx daemon restart`), missing or old `erofs-utils` (needs `--tar`,
  >= 1.8), and erofs kernel support (`sudo modprobe erofs`). `setup.sh`
  verifies all four on Linux. An occupied host port fails the run the same
  way -- `./sbx.sh check` now also tests that the four published ports are
  free. The built kit image stays cached, so a retry after a fix does NOT
  repeat the multi-minute build.
- `npm install failed for api|web`: the bootstrap now prints the real npm
  error to the terminal (last 30 lines of `workspaces/logs/npm-<app>.log`) and
  runs a curl pre-check first that separates egress problems (policy, proxy,
  DNS) from npm problems -- `registry.npmjs.org` IS in the kit allow-list, so
  a pre-check failure means the sandbox outbound path. The committed
  `package.json` files resolve cleanly (verified with a real `npm install`).
- `./sbx.sh ai` diagnoses the host <-> sandbox AI path in both directions;
  `./sbx.sh logs api|web|pg|adminer` tails the in-sandbox services.

## Requirements & notes

- Host: macOS 14+ (Apple silicon), Windows 11, or Ubuntu 24.04+ with **KVM**
  for local sandboxes. `sbx` does not require Docker Desktop. Debian is not
  officially tested but the same install path (`docker-sbx` apt package, KVM
  group) works -- see `setup.sh` output for the vendor-specific module names.
- On the host, Ollama must listen beyond loopback (`OLLAMA_BIND_HOST=0.0.0.0`,
  see `setup.sh` output) so the sandbox can reach it as
  `host.docker.internal:11434`. If the alias does not resolve in your setup,
  point `AI_OLLAMA_URL` at the host gateway IP -- `./sbx.sh ai` diagnoses both
  directions.
- Docs used for this template: [Usage](https://docs.docker.com/ai/sandboxes/usage/),
  [Environment files](https://docs.docker.com/ai/sandboxes/configuration/environment-files/),
  [Customize/kits](https://docs.docker.com/ai/sandboxes/customize),
  [Install](https://docs.docker.com/ai/sandboxes/install/),
  [Local governance](https://docs.docker.com/ai/sandboxes/configuration/local/),
  [pi providers](https://docs.pi.dev/latest/models). Field names and flags are
  as documented on 2026-11-24; if your `sbx` version differs, `./sbx.sh plan`
  and `sbx env --help` show the exact accepted schema.
