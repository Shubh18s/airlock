# Several agents at once

tmux is in the image, so one container can host several agents on the same repository.
Give each its own git worktree:

```bash
agent                                        # one container for the project
tmux                                         # inside it
git worktree add .worktrees/feat-a -b feat-a # one per pane
```

What parallel agents need is not isolation from each other -- they are your code at the
same trust level -- but separate working trees, so two are not editing the same files or
running `git checkout` under one another. Worktrees share one object store, so branches
are immediately visible across panes.

Create worktrees **inside** `/work`. A worktree's `.git` is a file holding an absolute
path to the main repo, so one created on the host points somewhere that does not exist in
the container and every git command fails. Created inside, the path resolves.

A second terminal joins the same session with
`docker exec -it agent-myproject tmux attach`.

## The shipped tmux config is minimal

Default prefix, no keybindings, no colours. `/etc/tmux.conf` sets only what being in a
container justifies:

- **100k scrollback**, because agent runs are long.
- **Mouse on**, because there is no host scrollback to fall back on.
- **Truecolor**, so diffs do not drop to 8 colours.
- **OSC 52** for the clipboard, since no `pbcopy` or X11 socket exists inside.
- **Zero escape-time**, so agent TUIs stop swallowing ESC.

Your own config layers on top: tmux reads `/etc/tmux.conf` before `~/.tmux.conf`, so
writing yours into a project's home volume overrides everything shipped.

## Persistence caveat

tmux is a child of the container's main process. Detaching tmux is safe, but **closing
the terminal that `agent` is attached to stops the container** and takes every pane with
it. For runs that must survive that, start the container detached and exec into it:

```powershell
docker run -d --name agent-myproject ... vestibule:1 sleep infinity
docker exec -it agent-myproject tmux new-session -A -s main
```

A `-Detach` switch is [backlog item 10](../BACKLOG.md).
