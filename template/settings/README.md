# Agent settings

A starting layout for `agent -Settings`. Copy this directory somewhere of your own,
put it under version control, and point the launcher at it:

```powershell
copy -Recurse "<vestibule>\template\settings" "$HOME\repos\my-agent-settings"
$env:VESTIBULE_SETTINGS = "$HOME\repos\my-agent-settings"
```

## What gets mounted

```
claude\CLAUDE.md   ->  ~/.claude/CLAUDE.md     read-only
claude\commands\   ->  ~/.claude/commands/     read-only
claude\skills\     ->  ~/.claude/skills/       read-only
claude\hooks\      ->  ~/.claude/hooks/        read-only
tmux.conf          ->  ~/.tmux.conf            read-only
```

Every entry is optional. A path that is not here is simply not mounted.

**A subdirectory is one harness's configuration; the root is what they all share.**
`claude\` is Claude Code's. `tmux.conf` is at the root because a multiplexer is not a
harness setting. Only `claude\` is implemented today.

## Editing it

Read-only in a session on purpose: these are instructions and executable hooks that apply
to every future session, so a session able to edit them is a session able to rewrite the
hook that gates its own commits.

To change them, run `agent` from inside this directory. It is then the project at `/work`,
writable like any other checkout, and you commit from there.

A correction learned while working on some *other* project goes to `~/.vestibule/outbox`,
which is mounted read-write for that purpose. Fold the good ones in later.

## Two things that will bite you

**Hooks are mounted, not wired.** See `claude/settings.json.example`.

**Commit `.gitattributes` before anything else.** A `.sh` file checked out with CRLF on
Windows makes the kernel look for an interpreter named `bash\r`; the hook then exits 127
instead of 2, and a `PreToolUse` hook that does not exit 2 does not block. The gate stops
gating while still looking installed. Untracked, `.gitattributes` protects only the one
working tree it sits in.
