#!/usr/bin/env bash
set -euo pipefail

MODEL_ID="${OLLAMA_MODEL:-inkling-2-mini}"

# 1. Install herdr (full server + CLI release) and ensure PATH
curl -fsSL https://releases.herdr.dev/app/install.sh | sh
curl -fsSL https://herdr.dev/install.sh | sh
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
grep -q '\.local/bin' "${HOME}/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"

# 2. Install OpenSpec and CLI utilities
npm install -g @fission-ai/openspec@latest
sudo apt-get update -y && sudo apt-get install -y gh vim curl git ripgrep

# 3. Official pi models.json pointing to host Ollama (inkling-2-mini)
mkdir -p "${HOME}/.pi/agent"
cat <<EOF > "${HOME}/.pi/agent/models.json"
{
  "providers": {
    "ollama": {
      "baseUrl": "http://192.168.122.1:11434/v1",
      "apiKey": "ollama",
      "api": "openai-completions",
      "models": [
        {
          "id": "${MODEL_ID}",
          "name": "${MODEL_ID}",
          "reasoning": false,
          "input": ["text"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 32768,
          "maxTokens": 8192
        }
      ]
    }
  }
}
EOF

# 4. Official pi settings.json setting ollama/inkling-2-mini as default model
cat <<EOF > "${HOME}/.pi/agent/settings.json"
{
  "defaultProvider": "ollama",
  "defaultModel": "${MODEL_ID}"
}
EOF

# 5. Official herdr config.toml
mkdir -p "${HOME}/.config/herdr"
cat <<'EOF' > "${HOME}/.config/herdr/config.toml"
[keys]
prefix = "ctrl+b"
new_tab = "prefix+c"
next_tab = "prefix+n"
previous_tab = "prefix+p"

[ui]
tab_bar_position = "top"
status_indicators = "symbols"
EOF

# 6. Authenticate gh CLI and git with Fine-Grained Token
if [ -n "${GITHUB_TOKEN:-}" ]; then
  printf "%s" "${GITHUB_TOKEN}" | gh auth login --with-token
  git config --global credential.helper store
  printf "https://x-access-token:%s@github.com\n" "${GITHUB_TOKEN}" > "${HOME}/.git-credentials"
  chmod 600 "${HOME}/.git-credentials"
fi

# 7. Create the 5 Factory Skills in ~/.pi/agent/skills/
mkdir -p "${HOME}/.pi/agent/skills"/{spec-analyst,solution-architect,spec-developer,qa-tester,code-reviewer}

cat <<'EOF' > "${HOME}/.pi/agent/skills/spec-analyst/SKILL.md"
---
name: spec-analyst
description: Analyze GitHub issues, define functional requirements, edge cases, and I/O contracts, and write OpenSpec proposal.md and specs/.
---
# Role 1: Spec Analyst (Tab 1: 1-analyst)
1. Inspect the assigned GitHub issue (`gh issue view <id>`).
2. Clarify functional requirements, edge cases, and standardized JSON I/O contracts (`{ ok, data, error }`).
3. Create/update OpenSpec `proposal.md` and `specs/` in English.
4. Exit Gate: When specs are complete, send a handoff message to Tab 2 (`2-architect`) via `herdr`. Otherwise do not send.
EOF

cat <<'EOF' > "${HOME}/.pi/agent/skills/solution-architect/SKILL.md"
---
name: solution-architect
description: Design modular architecture across Frontend, TypeScript API, PostgreSQL 19, and dbadmin, producing design.md and ordered tasks.md.
---
# Role 2: Solution Architect (Tab 2: 2-architect)
1. Read `proposal.md` and `specs/`.
2. Define module boundaries across `apps/web`, `apps/api`, PostgreSQL 19, and `dbadmin`, enforcing uniform I/O contracts.
3. Write `design.md` and atomic ordered tasks (`- [ ] ...`) in `tasks.md`.
4. Exit Gate: When `design.md` and `tasks.md` are ready, send a handoff message to Tab 3 (`3-developer`) via `herdr`. Otherwise do not send.
EOF

cat <<'EOF' > "${HOME}/.pi/agent/skills/spec-developer/SKILL.md"
---
name: spec-developer
description: Implement one atomic task from tasks.md on a feature branch following design.md and I/O standards.
---
# Role 3: Spec Developer (Tab 3: 3-developer)
1. Ensure work happens on `feat/issue-<id>-<slug>`.
2. Implement ONE unchecked task (`- [ ]`) at a time strictly adhering to `design.md` and I/O standards without unrequested edits.
3. Mark completed task as `- [x]` in `tasks.md`.
4. Exit Gate: When the task is implemented, send a handoff message to Tab 4 (`4-tester`) via `herdr`. Otherwise do not send.
EOF

cat <<'EOF' > "${HOME}/.pi/agent/skills/qa-tester/SKILL.md"
---
name: qa-tester
description: Write and execute unit, integration, and API/DB tests inside the sandbox and report real results.
---
# Role 4: QA Tester (Tab 4: 4-tester)
1. Write and run TypeScript unit/integration tests and HTTP/DB checks (`curl` / PostgreSQL queries) covering happy paths and error cases.
2. Report exact command outputs.
3. Exit Gate: If all tests pass, message Tab 5 (`5-reviewer`) via `herdr`. If any test fails, message Tab 3 (`3-developer`) with exact failure logs.
EOF

cat <<'EOF' > "${HOME}/.pi/agent/skills/code-reviewer/SKILL.md"
---
name: code-reviewer
description: Review git diff for scalability, maintainability, modularity, simplicity, and I/O consistency; archive OpenSpec, push branch, and open PR.
---
# Role 5: Code Reviewer (Tab 5: 5-reviewer)
1. Inspect `git status` and `git diff` for scalability, maintainability, modularity, simplicity, and I/O consistency.
2. Exit Gate (Reject): If issues remain, message Tab 3 (`3-developer`) with specific fixes.
3. Exit Gate (Approve): Run `openspec archive <change-name>`, commit and push (`git push -u origin <branch>`), and open the PR (`gh pr create`) linking `Closes #<id>`.
EOF

# 8. Final binary verification
pi --version
openspec --version
herdr --version
gh --version
git --version
curl --version
vi --version
