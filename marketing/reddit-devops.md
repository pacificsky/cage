# Reddit — r/devops

## Title

Using Docker containers to sandbox AI coding agents — wrote a CLI for it

## Body

AI coding agents (Claude Code, Codex) are most useful when given unrestricted shell access, but that's a non-starter on a machine with prod credentials, SSH keys, and real data.

I built **cage** — a bash CLI that creates isolated Docker containers per project directory. It's essentially developer environment management scoped to AI agent safety.

```
cage start              # create or re-attach
cage start -p 3000:3000 # with port forwarding
cage shell              # additional shell into running container
cage list               # all cage containers across projects
```

Architecture:
- Project dir mounted rw at the same absolute path
- Shared Docker volume (`cage-home`) for `/home/vscode` across all containers
- SSH agent socket forwarded
- Env file injection: global (`~/.config/cage/env`) + per-project (`.cage.env`)
- Seed directory for dotfile bootstrap
- Deterministic container naming: `cage-<dirname>-<8char-sha256>`
- Runtime detection: prefers docker, falls back to podman

It's a single bash script with no dependencies beyond a container runtime. Has unit tests (mock-based) and integration tests (real containers).

GitHub: https://github.com/pacificsky/cage

Curious how others are thinking about sandboxing for AI dev tooling — VMs, containers, nsjail, something else?
