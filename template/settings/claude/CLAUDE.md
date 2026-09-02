# Working conventions

Mounted read-only at `~/.claude/CLAUDE.md` by `agent -Settings`. Loaded into every request
in every session, so length is a tax: a line earns a place here only if it is true in every
repository and you would want it enforced with no context at all. Everything else belongs
in a project's own `CLAUDE.md` or in a skill.

## Environment -- vestibule container

Keep container facts in one block at the top, so using these conventions on another machine
means deleting down to the first convention heading and nothing more.

- Debian bookworm, bash. No PowerShell, no zsh, no WSL.
- One repository, bind-mounted at `/work`, and the only path that reaches the host disk.
  Everything else is on a Docker volume that `docker volume prune` destroys.
- No `gh`, no docker, no clipboard utility. Check before assuming a tool exists.
- Egress is restricted when the firewall is on, and a blocked request hangs rather than
  failing. A call that never returns usually means a domain that is not on the allowlist.

## Your conventions go here

Replace this section. Keep each rule to what to do and why -- a rule without its reason
gets discarded by the next agent that meets an edge case.
