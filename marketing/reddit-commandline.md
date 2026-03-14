# Reddit — r/commandline

## Title

cage: a bash script to isolate AI coding agents in Docker containers

## Body

I wrote a bash script that wraps Docker to create per-project containers for running AI coding agents (Claude Code, Codex, etc.) with full permissions.

The problem: these agents work best when you give them unrestricted shell access, but that means an LLM can `rm -rf` your home directory or curl things it shouldn't.

cage gives you a throwaway container:

```
cd ~/src/my-project
cage start              # creates/re-attaches to project container
cage shell              # second shell into the same container
cage list               # see all your project containers
cage restart            # fresh container, volumes preserved
```

Design choices I'm happy with:
- Project mounted at the same absolute path (not `/workspace` or `/app`)
- Deterministic container names from project path (`cage-myproject-a1b2c3d4`)
- Shared Docker volume for home dir across all containers
- Seed directory (`~/.config/cage/home/`) to pre-populate dotfiles
- No dependencies beyond bash and docker/podman

It's ~500 lines of bash with unit tests and integration tests. MIT licensed.

GitHub: https://github.com/pacificsky/cage

Happy to talk about the implementation — it's fairly straightforward Docker plumbing, but there were some interesting edge cases with runtime detection and container lifecycle.
