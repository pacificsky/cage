# Product Hunt

## Product Name

cage

## Tagline (60 chars max)

Run AI coding agents safely in isolated containers

## Description

cage is a CLI that wraps Docker to create isolated containers for running AI coding agents like Claude Code and Codex with full permissions — without risking your host machine.

One command to start:

```
cd ~/src/my-project
cage start
claude --dangerously-skip-permissions
```

Your project is mounted at the same absolute path, so error messages and file references just work. A shared home volume means credentials, git config, and shell history are configured once across all your projects.

It's a single bash script with no dependencies beyond Docker (or Podman). Works on macOS and Linux. MIT licensed.

## Topics

- Developer Tools
- Open Source
- Artificial Intelligence
- Docker
- Command Line

## Links

- GitHub: https://github.com/pacificsky/cage
- Blog: https://pacificsky.blog/posts/2026/03/13/cage-run-ai-coding-agents-without-fear/

## First Comment (post as maker)

Hey! I built cage because I wanted to run Claude Code with --dangerously-skip-permissions without worrying about what it might do to my actual machine.

The key insight is that your project directory gets mounted at the same absolute path inside the container — so all error messages, stack traces, and file references match your host. It feels like you're working locally, but the blast radius is contained.

Would love feedback — especially on what other features would make this useful for your workflow.
