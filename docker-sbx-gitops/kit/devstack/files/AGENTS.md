# devstack — Docker Sandbox agent guide

You are the coding agent of this sandbox. Everything below describes YOUR
environment; the developer drives you from the host with `./sbx.sh`.

## Layout

| Path | What it is |
|---|---|
| `/home/agent/workspaces/api` | TypeScript API (Express + pg). Dev server: `npm run dev` (tsx watch), port `$API_PORT`. |
| `/home/agent/workspaces/web` | React + TypeScript + Vite. Dev server: `npm run dev`, port `$WEB_PORT`, proxies `/api` → the API. |
| `/home/agent/workspaces/logs` | api.log / web.log / npm-*.log |
| `/home/agent/bootstrap/10-devstack.sh` | Idempotent bootstrap (idempotent — safe to re-run) |
| `/home/agent/.pi/agent/models.json` | pi provider config → host Ollama |
| `/etc/sandbox-persistent.sh` | Values synced from the host `etc.env` (sourced by `.devstack_env`) |

## Services (all components communicate)

| Component | Address (inside sandbox) | Notes |
|---|---|---|
| Postgres dev | `127.0.0.1:$PG_PORT` (host processes) or `$POSTGRES_HOST:5432` (containers) | container `pg-dev` on docker network `$SBX_NET_NAME`; creds `$POSTGRES_USER` / `$POSTGRES_PASSWORD` / `$POSTGRES_DB` |
| Adminer | `127.0.0.1:$ADMINER_PORT` | container `adminer-dev`; server field = `$POSTGRES_HOST` |
| API | `127.0.0.1:$API_PORT` | `GET /api/health` pings Postgres and reports latency |
| Web | `127.0.0.1:$WEB_PORT` | Vite dev server; `/api/*` proxied to the API |
| Host Ollama | `$AI_OLLAMA_URL` | local AI used by pi; `$AI_PROVIDER=model-runner` switches to `$AI_MODEL_RUNNER_URL` |

## Agent tools

- `pi` — coding agent. First run: `/login` is not needed for Ollama; pick the
  `ollama` provider with `/model` (models come from `~/.pi/agent/models.json`).
- `herdr` — terminal multiplexer that owns agent terminals. Start it with
  `herdr`, detach with `ctrl+b q`, reattach with `herdr`.
- `openspec` — spec-driven development CLI (`openspec --help`).

## House rules

- Restart a service after edits: `bash /home/agent/bootstrap/10-devstack.sh`
  (idempotent) or `pkill -f tsx` and start it again with nohup, logging to
  `/home/agent/workspaces/logs/`.
- Postgres data lives in the named docker volume `$PGDATA_VOLUME` — do not
  `docker rm -v` it casually.
- Dev credentials are in the environment (`POSTGRES_*`); never put them in
  committed code — read them from `process.env`.
