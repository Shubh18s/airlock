# The devcontainer path

Copied into a project as `.devcontainer/` by `New-AgentDevcontainer`, so VS Code's
*Reopen in Container* gives the same isolation as `agent`.

```powershell
cd ~\repos\any-project
New-AgentDevcontainer
# Ctrl+Shift+P -> Dev Containers: Reopen in Container
```

`devcontainer.json` is a declarative wrapper around the same docker flags, and it reuses
the home volume name `agent` derives, so both launchers share one login and one session
history.

## Two placeholders

`New-AgentDevcontainer` substitutes both at generation time, because JSON has no
variables:

- `__PROJECT__` becomes the folder name, which fixes the home volume name.
- `__VESTIBULE__` becomes the path to this repository, which `initializeCommand` needs.

Regenerate with `-Force` after changing the template, or after moving this repository.

## Sessions are recorded

`initializeCommand` runs on the **host** before the container is created -- the only
devcontainer hook outside the session's reach, which is what makes the record worth
keeping. There is no matching host-side hook for a session *ending*, so these rows carry
nulls rather than zeros for duration and outcome: unknown, not clean.

Read them with `Get-AgentSessions`, where the `Via` column distinguishes the two paths.

## What this path cannot do

**The egress allowlist.** `agent -Firewall` starts the container as root, applies
iptables, then hands the session to an unprivileged user via `setpriv` with
`no-new-privileges` intact. A devcontainer's lifecycle hooks run as the remote user, so
the equivalent would need `sudo` -- which `no-new-privileges` refuses by design. Making
it work means dropping that hardening for the whole session and leaving a permanent
escalation path.

So for any posture other than the default, use `agent` and attach the editor instead:

```powershell
agent -Firewall
# Ctrl+Shift+P -> Dev Containers: Attach to Running Container -> agent-<project>
```

That keeps one implementation of each control rather than a second, weaker one. Note
that `agent` uses `--rm`, so closing the terminal it runs in stops the container and
takes the attached editor with it.

## Editing it

`runArgs` passes straight to docker, so anything you can express there works here. The
mount list is the security policy: adding an entry is the one change that meaningfully
widens what a session can reach.
