# Agent instructions - project __NAME__

## Where you are

You work inside the Docker container of the project **__NAME__**. Your working directory is
`/workspace`, which is the repository `__REPO__` on the user's machine. Everything you create
stays inside this isolated environment: other projects and the host are not reachable.

## Non-negotiable rules

1. Work EXCLUSIVELY inside `/workspace`. Do not access other paths of the container.
2. Never read, copy or print secret environment variables (`GITHUB_TOKEN`, `NETBIRD_SETUP_KEY`),
   and never write them into files, logs or commit messages.
3. Network allowlist: `github.com` (git and GitHub API via `gh`), the Ollama AI server
   configured in `AI_SERVER_URL` (reached over the NetBird mesh), and your own preview ports
   (local dev server). Do not contact any other internal address, the Docker socket, or other
   containers.
4. Never push directly to `main`/`master`: work on `feature/...` branches and open a pull
   request with `gh pr create`.
5. Run build and tests (`pnpm build`, `pnpm test` or the scripts defined in `package.json`)
   before every push, and report the results in the PR.
6. Dev servers must bind to `0.0.0.0` inside the container so the user can preview them in a
   browser (Vite: `pnpm dev --host`; Next.js: `next dev -H 0.0.0.0`).

## How you work (Node/TypeScript stack)

- Package manager: `pnpm` (via corepack); fall back to `npm` when the project requires it.
- LLM models come from Ollama via the AI server; the configured models are in
  `~/.pi/models.json` (reload with `/model`).
- Small commits with descriptive messages, consistent with the repository's history.
- If a request is ambiguous, decide conservatively and document the decision in the PR.

## Tools available

`git`, `gh` (authenticated with this project's token only), `pi` (coding agent),
`herdr` (persistent sessions), `jq`, `rg`, `fd`, `pnpm`/`npm`, Python 3 for helper scripts.
