# Show HN

## Title

Show HN: Cage – Run AI coding agents safely in isolated containers

## URL

https://github.com/pacificsky/cage

## Text (optional, since URL is provided — but useful for context)

I built cage because I wanted to run Claude Code and Codex with --dangerously-skip-permissions without worrying about what they'd do to my host machine.

It's a single bash script that wraps Docker to create isolated containers per project. Your project directory is mounted at the same absolute path, so error messages and file references just work. A shared home volume means credentials, git config, and shell history are configured once across all projects.

Usage:

    cd ~/src/my-project
    cage start
    claude --dangerously-skip-permissions

Works with Docker, Podman, or Colima on macOS and Linux. MIT licensed.

Blog post with the full backstory: https://pacificsky.blog/posts/2026/03/13/cage-run-ai-coding-agents-without-fear/
