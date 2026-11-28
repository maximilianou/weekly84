#!/usr/bin/env bash
set -euo pipefail

MODEL_ID="${OLLAMA_MODEL:-inkling-2-mini}"

# 1. Install herdr server + CLI (releases.herdr.dev/app/install.sh)
curl -fsSL https://releases.herdr.dev/app/install.sh | sh

# 2. Install @fission-ai/openspec and gh CLI / base tools
npm install -g @fission-ai/openspec@latest
sudo apt-get update -y && sudo apt-get install -y gh vi curl git ripgrep

# 3. Official pi models.json for local Ollama OpenAI-compatible endpoint
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

# 4. Official herdr config.toml
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

# 5. Create the 5 role skills under ~/.pi/agent/skills/
mkdir -p "${HOME}/.pi/agent/skills"/{spec-analyst,solution-architect,spec-developer,qa-tester,code-reviewer}

cat <<'EOF' > "${HOME}/.pi/agent/skills/spec-analyst/SKILL.md"
---
name: spec-analyst
description: Analyze GitHub issues or prompts, define requirements, edge cases, and I/O contracts, and write OpenSpec proposal.md and specs/.
---
# Spec Analyst (Role 1)
Read the target GitHub issue (`gh issue view <n>`) or user prompt.
Produce clear functional requirements, edge cases, and standardized JSON I/O contracts (`{ ok, data, error }`).
Create or update OpenSpec artifacts (`proposal.md` and `specs/`) in English.
When finished, send a concise handoff message via `herdr` to Role 2 (`solution-architect`).
EOF

cat <<'EOF' > "${HOME}/.pi/agent/skills/solution-architect/SKILL.md"
---
name: solution-architect
description: Design modular architecture across Frontend, TypeScript API, PostgreSQL 19, and dbadmin, writing design.md and ordered tasks.md.
---
# Solution Architect (Role 2)
Read the OpenSpec proposal and specs.
Design modular boundaries across `apps/web`, `apps/api`, PostgreSQL 19, and `pgadmin` (`dbadmin`), enforcing uniform I/O contracts.
Write `design.md` and atomic ordered checkboxes in `tasks.md` (`- [ ] ...`).
When finished, send a concise handoff message via `herdr` to Role 3 (`spec-developer`).
EOF

cat <<'EOF' > "${HOME}/.pi/agent/skills/spec-developer/SKILL.md"
---
name: spec-developer
description: Implement one atomic task from tasks.md on a feature branch following design.md and I/O standards, marking tasks complete.
---
# Spec Developer (Role 3)
Ensure you are on a feature branch (`feat/issue-<id>-<slug>`).
Implement ONE unchecked task (`- [ ]`) at a time from `tasks.md` strictly according to `design.md` and I/O standards. Avoid unrequested edits.
Mark completed tasks as `- [x]` in `tasks.md`.
When a task is ready for verification, send a handoff message via `herdr` to Role 4 (`qa-tester`).
EOF

cat <<'EOF' > "${HOME}/.pi/agent/skills/qa-tester/SKILL.md"
---
name: qa-tester
description: Write and run unit, integration, and API/DB checks inside the sandbox, verifying error paths and reporting real results.
---
# QA Tester (Role 4)
Write and run TypeScript unit/integration tests and verify HTTP/DB endpoints with `curl` and PostgreSQL checks.
Test happy paths and error cases thoroughly.
Report real command outputs and pass/fail status. If tests pass, notify Role 5 (`code-reviewer`) via `herdr`; if issues fail, send exact failure details back to Role 3 (`spec-developer`).
EOF

cat <<'EOF' > "${HOME}/.pi/agent/skills/code-reviewer/SKILL.md"
---
name: code-reviewer
description: Review git diff for scalability, maintainability, modularity, simplicity, and I/O consistency; prepare commit, push, issue link, and PR.
---
# Code Reviewer (Role 5)
Inspect `git status` and `git diff` for scalability, maintainability, modularity, simplicity, and consistent I/O contracts.
If fixes are needed, send specific review notes to Role 3 (`spec-developer`).
When approved, archive the OpenSpec change (`openspec archive <change-name>`), stage/commit/push the branch (`git push -u origin <branch>`), link/close the issue in the PR body, and open the PR via `gh pr create`.
EOF

# 6. Verify installed binaries
pi --version
openspec --version
herdr --version
gh --version
git --version
curl --version
vi --version
