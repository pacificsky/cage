# Reddit — r/ClaudeAI

## Title

I built "cage" to safely run Claude Code with --dangerously-skip-permissions in isolated containers

## Body

I've been using Claude Code heavily, and the most productive way to use it is with `--dangerously-skip-permissions` — but running that on your actual machine is nerve-wracking.

So I built **cage**: a CLI that spins up an isolated Docker container for each project. Your code is mounted at the same absolute path, so everything just works — error messages, file paths, tooling.

```
cd ~/src/my-project
cage start
claude --dangerously-skip-permissions
```

What makes it practical:
- **Shared home volume** — Claude credentials, git config, shell history all persist across projects. Configure once.
- **Port forwarding** — `cage start -p 3000:3000` for web dev
- **`cage shell`** — open a second terminal while Claude is running
- **No config files** — it's a single bash script, no devcontainer.json or Dockerfile needed

Works with Docker Desktop, Colima, or Podman on macOS and Linux.

`brew install pacificsky/tap/cage`

GitHub: https://github.com/pacificsky/cage

Full write-up: https://pacificsky.blog/posts/2026/03/13/cage-run-ai-coding-agents-without-fear/

Would love to hear how others are handling the permissions trade-off with Claude Code.
