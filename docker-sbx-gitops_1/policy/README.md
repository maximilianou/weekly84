# Network policy — devstack

The sandbox's outbound TCP traffic is evaluated by a host-side proxy against
your rules; UDP and ICMP are blocked by default. Two layers apply here:

1. **Kit-level allow-list** — `kit/devstack/devstack.yaml`
   (`com.docker.sandbox/network-policy@1` → `config.runtime.allow`). This ships
   with the repo, so every environment created from it gets the same baseline.
   This is the GitOps layer.
2. **Host policy** — `sbx policy` commands and the `sbx` TUI network panel.
   Presets: `allow-all` / `balanced` (default, deny + baseline allowlist) /
   `deny-all` (explicit rules only). `./setup.sh` adds the host-AI rule so
   pi can reach Ollama regardless of the preset.

## Rules shipped in the kit

| Destination | Why |
|---|---|
| `registry.npmjs.org`, `deb.nodesource.com` | npm installs, Node toolchain |
| `pi.dev`, `docs.pi.dev` | pi coding agent + docs |
| `herdr.dev` | herdr installer / updates |
| `github.com`, `api.github.com`, `objects.githubusercontent.com`, `raw.githubusercontent.com` | openspec, git operations, installers |
| `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` | `docker pull` of postgres/adminer INSIDE the sandbox |
| `host.docker.internal` | local AI on the host (Ollama on :11434) |
| `model-runner.docker.internal` | Docker Model Runner fallback endpoint |

## Useful commands

```bash
sbx policy ls                                   # view included rules
sbx policy allow network "host.docker.internal:11434"   # host Ollama
sbx policy allow network "myhost.example:22"    # any host:port
```

The `sbx` TUI (run bare `sbx`) has a network panel to browse connection logs
and allow/block hosts interactively — handy to discover what your tools need,
then codify the finding into `devstack.yaml` via a pull request. That is the
GitOps loop: observation → rule → committed config.
