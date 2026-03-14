# Reddit — r/ChatGPTCoding

## Title

Open source CLI to sandbox AI coding agents (Claude Code, Codex) in Docker containers

## Body

I've been running AI coding agents with full permissions to get the best results, but giving an LLM unrestricted shell access on my actual machine felt like a bad idea.

**cage** is a CLI I built to solve this. It wraps Docker to create an isolated container per project:

```
cd ~/src/my-project
cage start
claude --dangerously-skip-permissions
# or: codex --full-auto
```

Key design decisions:
- Your project is mounted at the **same absolute path** — error messages and file references match your host, no mental translation needed
- A **shared home volume** across all projects means credentials, git config, and shell history are set up once
- It's a **single bash script** — no devcontainer config, no Dockerfile, no YAML

Also supports port forwarding, SSH agent forwarding, env file injection, and opening additional shells while an agent is running.

Works with Docker, Podman, or Colima. macOS and Linux. MIT licensed.

GitHub: https://github.com/pacificsky/cage

Blog post: https://pacificsky.blog/posts/2026/03/13/cage-run-ai-coding-agents-without-fear/
