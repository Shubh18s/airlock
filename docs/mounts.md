# Mounts and write scope

What a session can read, what it can write, and where a write ends up. The mount list is
the security policy, so this is the file to check when deciding whether a session can
reach something.

Assembled in `agent.ps1`, in a single block, deliberately: mounts declared anywhere else
apply to every posture including ones they were never reviewed against.

## The default posture

`agent` from inside a project directory.

```
  HOST (Windows)                                  CONTAINER  agent-<project>
  ==============                                  =========================

  <project>\ ------------------- bind  rw ------> /work            [w]  cwd
    .vestibule\
      allowed-domains.txt                           .vestibule/allowed-domains.txt
                                                      ^ AGENT_ALLOWLIST, -Firewall only

  %USERPROFILE%\.claude\          (only when -Settings is NOT given)
    CLAUDE.md ------------------ bind  ro ------> /home/dev/.claude/CLAUDE.md   [r]
    .credentials.json    never mounted
    history.jsonl        never mounted
    projects\            never mounted

  <settings>\                    -Settings only; each entry optional
    claude\CLAUDE.md ----------- bind  ro ------> /home/dev/.claude/CLAUDE.md   [r]
    claude\commands\ ----------- bind  ro ------> /home/dev/.claude/commands    [r]
    claude\skills\ ------------- bind  ro ------> /home/dev/.claude/skills      [r]
    claude\hooks\ -------------- bind  ro ------> /home/dev/.claude/hooks       [r]
    tmux.conf ------------------ bind  ro ------> /home/dev/.tmux.conf          [r]

  %LOCALAPPDATA%\vestibule\
    sessions.jsonl       never mounted   (written host-side, after the session)
    outbox\ -------------------- bind  rw ------> /home/dev/.vestibule/outbox   [w]
                                                    ^ -Settings only. The one
                                                      writable settings path.


  DOCKER VOLUMES  (inside the Linux VM; not on the host filesystem)
  ================================================================

  agent-home-<project> --------- vol   rw ------> /home/dev        [w]
                                                    .claude/    login, transcripts, memory
                                                    .venv/      UV_PROJECT_ENVIRONMENT
                                                    .bashrc

  uv-cache   SHARED, every project -- vol rw ---> /home/dev/.cache/uv   [w]


  IMAGE LAYER  (root-owned: writable filesystem, but `dev` cannot write)
  =====================================================================

  /etc/tmux.conf                     0644 root
  /usr/local/bin/init-firewall.sh    0755 root
  /etc/sudoers.d/10-init-firewall    0440 root

  anything else (/tmp, ...)          [w] but discarded: the container runs --rm
```

`[w]` writable by the agent, `[r]` readable only.

## Where a write actually persists

Writability is two questions, not one: the mount mode, and the unix ownership underneath
it. `/etc/tmux.conf` sits on a writable filesystem and is still unwritable, because it is
owned by root and the session runs as `dev`.

| Path | Mode | Survives the session | Crosses a boundary |
|---|---|---|---|
| `/work` | rw | yes | **reaches the host filesystem** |
| `/home/dev` | rw | yes, in the volume | no, and per project |
| `/home/dev/.cache/uv` | rw | yes, in the volume | **shared by every project** |
| `/home/dev/.claude/CLAUDE.md` | ro | n/a | cannot be written |
| `~/.claude/{commands,skills,hooks}` | ro | n/a | cannot be written |
| `/home/dev/.vestibule/outbox` | rw | yes | **reaches the host filesystem** |
| root-owned image paths | n/a | n/a | cannot be written |
| everything else | rw | no, `--rm` discards it | no |

Three rows carry the risk. `/work` is a bind, so a write there lands on the host. So does the
outbox, deliberately and narrowly: mounting settings read-only is this launcher's choice, so
somewhere a session can still write about them is its obligation. It carries proposed changes
and nothing else, and it is the only writable settings path.

It sits under `~/.vestibule` rather than `~/.claude` because that directory belongs to one
harness and holds its credential, transcripts and settings. The outbox is not part of any
harness's configuration, so it stays put whichever one is running. `uv-cache` is shared across
projects by design, since it holds public artifacts only, which is also why an isolated
session does not receive it.

`/home/dev` is keyed on the project directory's leaf name, so two repositories both named
`api` share one home volume, and with it a login and every transcript. See `BACKLOG.md`.

## `-Isolated`

Mounts nothing from this machine. Not the project, and equally not the login, the
transcripts or the preferences.

```
  agent-scratch-<project> ------ vol   rw ------> /work    [w]

  (no home volume, no uv-cache, no CLAUDE.md, no host bind of any kind)
```

`/home/dev` is then the image layer: writable, and discarded when the container exits.
The cost is a login per session. The gain is a container holding no credential worth
taking.

## Why the global CLAUDE.md is read-only

It is mounted `:ro` at `agent.ps1:389`, and only that one file. Never the whole
`~/.claude`, which holds the host credential and every past project's transcripts.

Read-only because a file the agent can edit is not a constraint on the agent. The mode is
doing real work here: `CLAUDE.md` is not data, it is instructions that apply to every
future session on every project, so write access to it is write access to the behaviour
of every session that follows.

The practical consequence is that a correction made mid-session cannot be recorded from
inside the session. That is the control working, not a defect. Amend it on the host.

## Capabilities and network, for completeness

Neither is a mount, but both decide what a session can reach.

```
  default     --cap-drop=ALL  --security-opt=no-new-privileges
              --pids-limit=512  --memory=8g  --cpus=4
              --network agent-net-<project>      per-project bridge

  -Firewall   + NET_ADMIN NET_RAW SETUID SETGID, during startup only.
              Starts as root, writes iptables rules, setpriv hands off to dev.
              no-new-privileges is retained, so the session cannot climb back.

  -NoNetwork  --network=none. No egress at all, including to the agent's own API.
```

A per-project network exists because on Docker's default bridge every container can reach
every other by IP. There is no name resolution there, but an address is enough to scan a
sibling and defeat per-project isolation.

## Environment set in the image

| Variable | Value | Why |
|---|---|---|
| `UV_PROJECT_ENVIRONMENT` | `/home/dev/.venv` | Keeps the virtualenv off the bind mount. Without it uv writes `.venv` beside the `pyproject.toml`, which for a bind-mounted project means a Linux venv on the host: useless there, and destructive when the host already keeps an environment by that name. |
| `LANG` | `C.UTF-8` | Debian slim sets no locale; tmux then mangles multi-byte UTF-8. |

Set in the image rather than `~/.bashrc`, which is read only by interactive shells. An
agent running `uv sync` non-interactively would miss it and write to the bind mount.
