# aienv - isolated AI development environments

A small bash toolkit that gives every project (e.g. `weekly85`, `weekly86`) its **own Docker
container** where [pi](https://pi.dev) (coding agent) and [herdr](https://herdr.dev) (the
runtime your coding agents live on) work. Each environment has its own network, its own
workspace, a **GitHub PAT limited to that single repository**, and its own **NetBird peer** on
your self-hosted mesh. Environments can run on any machine in the mesh, reach the shared AI
(Ollama) server by **MagicDNS name**, and be previewed in a browser from anywhere - without
publishing any public port.

```
your NetBird mesh (self-hosted, MagicDNS domain: *.netbird.selfhosted in this example)

  laptop ── herdr (one window, ALL environments via SSH remote machines)
     │
     ├── aienv-weekly85 ── ssh dev@weekly85.netbird.selfhosted:22
     │      container: /workspace (bind mount), pi + herdr + git + gh + node LTS
     │      preview:  http://weekly85.netbird.selfhosted:3000   (no ports published)
     │      AI:       http://desk01.netbird.selfhosted:11434    (Ollama, by name)
     ├── aienv-weekly86  (same structure, fully isolated: different network, token, peer)
     └── desk01          your AI server: ollama serve, reachable by name from every peer
```

## Layout on your machine

```
~/aienv/                      <- the toolkit (this folder, git repo)
├── aienv                     <- single CLI entrypoint
├── lib/                      <- shared helpers + command implementations
├── templates/                <- Dockerfile, entrypoint, compose, AGENTS.md, models.json
├── config/
│   ├── aienv.conf            <- COMMITTABLE defaults (AI server URL, models, resources)
│   ├── aienv.secrets         <- PRIVATE fallbacks (SSH key, tokens) - gitignored
│   └── aienv.secrets.example <- template to copy
└── projects/                 <- one folder per environment (override: projects_dir or $AIENV_PROJECTS)
    └── weekly85/
        ├── workspace/        <- THE repository; the only folder the agent can touch
        │   └── AGENTS.md     <- rules pi loads automatically
        ├── aienv.config      <- committable project settings (ports, models, resources)
        ├── .env              <- PRIVATE (PAT, setup key, AI server URL) - never commit
        ├── gitconfig         <- project git identity (mounted read-only)
        ├── pi-models.json    <- Ollama models for pi (mounted read-only)
        ├── netbird-state/    <- persistent NetBird enrollment (survives recreation)
        └── docker-compose.yml <- generated
```

## Requirements

| What | Notes |
| --- | --- |
| Docker Engine + compose v2 | `docker compose version` must work; `modprobe tun` for the NetBird client |
| Ollama somewhere in your mesh | e.g. on `desk01.netbird.selfhosted`, with the models pulled (`ollama pull qwen2.5-coder:3b qwen2.5-coder:7b`) |
| Self-hosted NetBird | your management console; one setup key per project (auto-group `proj-<name>`) |
| GitHub fine-grained PAT | one per project, limited to that repo (scopes below) |
| git on the host | commit identity is inherited from `git config --global` |

## Install

```bash
cd ~/aienv
cp config/aienv.secrets.example config/aienv.secrets   # then fill in SSH_PUBLIC_KEY, chmod 600
vi config/aienv.conf                                   # set AI_SERVER_URL + NB_MANAGEMENT_URL
aienv install                                          # builds aienv-base (10-15 min the first time)
```

`aienv install` builds from `node:lts-bookworm` (always the latest stable Node LTS) with
`apt-get upgrade` at build time, so every environment starts from the latest stable patch
level. pi and herdr are always installed from their latest stable release.

## Configuration (committable vs private)

| File | Committed? | Contents |
| --- | --- | --- |
| `config/aienv.conf` | YES | AI server URL, model list, management URL, Node image, TZ, preview ports, resource defaults |
| `config/aienv.secrets` | NO (gitignored) | SSH public key, optional fallback PAT / setup key |
| `<project>/aienv.config` | YES (if you keep project settings in a repo) | preview ports + host ports, models, resources, repo |
| `<project>/.env` | NO | `GITHUB_TOKEN`, `NETBIRD_SETUP_KEY`, `NB_MANAGEMENT_URL`, `AI_SERVER_URL`, `SSH_PUBLIC_KEY` |

Precedence (first match wins): project `.env` > project `aienv.config` > toolkit secrets >
toolkit conf. After editing: `aienv render <name>`, then `aienv stop <name> && aienv start
<name>` (or `aienv update`) to recreate the container.

## Creating an environment

```bash
# typical case: existing GitHub repository
aienv create weekly85 --repo myuser/weekly85

# repository that does not exist yet: create it private (needs gh auth on the host)
aienv create weekly86 --create-repo

# everything in one line, NetBird included
aienv create weekly87 --repo myuser/weekly87 --token github_pat_xxx \
  --setup-key <SETUP_KEY> --management-url https://your-netbird-management
```

`create` clones (or `git init`), writes `.env` (600) + `aienv.config`, renders
`docker-compose.yml` and `pi-models.json`, writes `workspace/AGENTS.md` (if the repo has none)
with the agent rules, picks stable host ports, and starts the container.

**GitHub token**: create a fine-grained PAT at <https://github.com/settings/personal-access-tokens/new>
with *Repository access -> only this project's repo*, permissions **Contents RW, Pull requests
RW, Issues RW, Metadata R** (add *Workflows RW* only if the repo has Actions to update). It
lives only in this project's container: even if leaked, access is limited to one repository.

## Working day by day

```bash
aienv enter weekly85        # attach herdr (reconnects to the existing session)
aienv enter weekly85 --shell
aienv shell weekly85        # plain bash
aienv pi weekly85           # run pi directly
aienv pi weekly85 -p "update deps and open a PR"
aienv status                # all environments: state, CPU/MEM, mesh, AI reachability, repo
aienv stop weekly85         # stop (code stays, herdr sessions do not)
aienv start weekly85
```

Inside herdr (prefix `ctrl+b`): `ctrl+b v` split, `ctrl+b -` split vertical, `ctrl+b c` new
tab, `ctrl+b n`/`ctrl+b p` next/previous tab, `ctrl+b ?` all keys, `ctrl+b q` detach, `herdr
server stop` stops everything. Panes are marked **working / blocked / idle**, so you always
know which agent needs you. Detaching keeps agents running.

## NetBird: AI server by name, environments as peers

The NetBird client runs **inside each environment container** (official apt client, same
pattern as NetBird's own Docker image: `netbird service run` + `netbird up`). This is what
makes **MagicDNS names work inside the container**, so:

- **AI server by name from everywhere**: `AI_SERVER_URL=http://desk01.netbird.selfhosted:11434`
  (set in `aienv.conf`, override per project in `.env`). Any environment - on your PC, on
  another server, in another VM - reaches the same AI by the same name. The `*.netbird.selfhosted`
  suffix is whatever DNS domain your self-hosted NetBird management uses; peer hostnames
  (`desk01`, `emilia`, ...) are the names you enroll them with.
- **Environments are peers**: the peer hostname is the project name, so the environment is
  reachable as `<project>.<your-netbird-domain>` (ssh, preview, anything it serves) from any
  mesh device - laptop, phone with the NetBird app, another server.
- **Run an environment on another machine**: install Docker + NetBird there, clone this
  toolkit, run `aienv install && aienv create ...` with the same `aienv.conf` - the new
  environment enrolls as a peer and reaches the AI server by name. Nothing else to configure.

```bash
aienv netbird enroll weekly85 <SETUP_KEY> --url https://your-netbird-management
aienv netbird status weekly85 | ip weekly85 | logs weekly85
aienv netbird off weekly85     # disable the peer for this environment
```

**Setup keys**: create one setup key per project in your management console with auto-group
`proj-<name>`. In the console keep the default deny and add only:

| Name | Source | Destination | Flow |
| --- | --- | --- | --- |
| `users->projects` | group `users` (your devices) | `proj-weekly85`, `proj-weekly86`, ... | All (or only what you need) |
| `projects->infra` | `proj-*` | group of your NetBird server | management/signal/relay ports |

**Never** create rules between `proj-*` groups: projects stay invisible to each other.

## Monitoring and observability

- `aienv status` - one row per environment: state, token, CPU/MEM (docker stats), NetBird
  state + peer IP, AI server reachability (HTTP check from inside the container), repo, plus
  preview URLs and SSH targets.
- `aienv monitor weekly85` - live detail: resource usage vs limits, top processes inside the
  container, NetBird status, AI server check, preview URLs. Add `--watch 5` to refresh every
  5 seconds.
- `herdr` pane states (working / blocked / idle) tell you what every agent is doing right now.
- **One window for all environments**: herdr supports remote machines over SSH. Add each
  environment with the printed targets (`ssh dev@<peer-ip>` or `ssh dev@localhost -p <port>`)
  and you see and drive every agent of every environment from a single herdr on your laptop.
- `docker logs aienv-<name>` shows the entrypoint milestones; the NetBird detail log is
  `/var/log/aienv.log` inside the container (`aienv netbird logs <name>`).

## Browser preview (not just curl)

The dev server inside the container must bind `0.0.0.0` (Vite: `pnpm dev --host`; Next:
`next dev -H 0.0.0.0` - the AGENTS.md rules tell the agent to do this). Then:

- **locally**: `http://localhost:<host-port>` - every project gets stable, non-overlapping
  host ports for `3000 5173 8080` (set in `aienv.config`, rendered into compose, bound to
  `127.0.0.1`);
- **from anywhere in the mesh**: `http://<peer-ip>:3000` or, with MagicDNS,
  `http://<project>.<your-netbird-domain>:3000` - no public ports, no port publishing needed;
- `aienv status` / `aienv monitor` print the exact URLs per environment.

## Deployment

Deployment is **not** part of aienv - by design. aienv owns *development environments*; the
*project repository* owns its deployment (its own `Dockerfile`, CI workflow, hosting config,
infrastructure-as-code). The agent inside an environment can absolutely *write* those files
and open PRs for them, but releases run from CI or a dedicated production context - never
from inside a dev environment. This keeps the blast radius of any agent mistake limited to
its own workspace.

## Updating to the latest stable everything

```bash
aienv update
```

Rebuilds `aienv-base` (latest Node LTS + latest apt packages + latest GitHub CLI + latest
NetBird client + latest pi + latest herdr) and recreates every **running** environment with
the new image. Stopped environments pick the new image at their next `aienv start`. Recreated
environments lose herdr sessions (the code is safe; agents are restarted by you).

## Isolation: what the agent can and cannot do

| Layer | The agent CAN | The agent CANNOT |
| --- | --- | --- |
| Filesystem | read/write only `/workspace` (project bind mount) | touch other projects or the rest of your machine |
| Docker network | reach `github.com`, the AI server, its own preview ports | reach other environments (separate networks) |
| Credentials | use a PAT limited to one repository | push to or open issues on any other repo |
| NetBird mesh | be reachable from you as a peer | see or contact other projects' peers (default deny) |
| Host | - | publish ports, touch the Docker socket, install anything on your machine |
| Resources | run as long as needed | exceed MEM/CPU/PIDs limits (per project in `aienv.config`) |

**Honest limits**: internet egress goes through Docker NAT (needed for git/gh/npm - add an
egress proxy if you want domain filtering). The NetBird client inside the container needs
`NET_ADMIN/SYS_ADMIN` capabilities, but only on that environment's own network namespace -
the same requirement as NetBird's official Docker client. The entrypoint **unsets**
`NETBIRD_SETUP_KEY` and `SSH_PUBLIC_KEY` before dropping to the work user, so agents never
see them; the GitHub PAT is visible by necessity (gh uses it) and is scoped to one repo.

## Command reference

| Command | What it does |
| --- | --- |
| `aienv install [--node-image X]` | build the shared `aienv-base` image |
| `aienv create <name> [options]` | create an environment (repo, config, ports, start) |
| `aienv render <name>` | re-render compose + models.json after config edits |
| `aienv start <name>` / `aienv stop <name>` | start / stop an environment |
| `aienv enter <name> [--shell]` | attach herdr (or plain bash) |
| `aienv pi <name> [args...]` | run pi inside the environment |
| `aienv status` | overview of all environments |
| `aienv monitor <name> [--watch N]` | live resources/processes view |
| `aienv models <name> [model]` | show / change pi's Ollama models (default `qwen2.5-coder:3b`) |
| `aienv netbird <name> enroll/off/status/ip/logs/ssh` | manage the environment's mesh peer |
| `aienv update` | rebuild image with latest everything, recreate running envs |
| `aienv destroy <name> [--all]` | remove an environment (and with `--all` the folder, confirmed) |

## Troubleshooting

- **pi cannot reach the AI server** -> `aienv monitor <name>` shows the HTTP check. Inside the
  container: `curl $AI_SERVER_URL`. If the name does not resolve, the NetBird client is not
  connected: `aienv netbird status <name>`, `aienv netbird logs <name>`, and check that the
  AI host is actually enrolled in your mesh (`ollama list` on it). Models missing:
  `ollama pull <model>` on the AI server. In pi, `/model` reloads `models.json`.
- **NetBird does not connect** -> `aienv netbird logs <name>`; typical causes: missing
  `/dev/net/tun` on the host (`modprobe tun`), empty `NB_MANAGEMENT_URL`, expired setup key
  (enrollment state persists in `netbird-state/`, so one-off keys survive restarts).
- **herdr not found in the container** -> `aienv shell <name>` then
  `curl -fsSL https://herdr.dev/install.sh | sh`; for pi:
  `npm i -g --ignore-scripts @earendil-works/pi-coding-agent`.
- **`dubious ownership` from git** -> the image UID differs from your user: run
  `aienv install` again with the same user that manages the projects.
- **Port conflict for preview/SSH** -> the ports were picked at create time and are stored in
  `aienv.config`; free the conflicting port or edit `PREVIEW_HOST_PORTS`/`SSH_HOST_PORT`, then
  `aienv render <name>`.
- **Browser cannot open the preview** -> the dev server is probably bound to localhost inside
  the container: restart it with `--host` (Vite) or `-H 0.0.0.0` (Next).
