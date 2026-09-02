# Backlog

Known gaps, roughly in priority order. Each entry states the gap, why it matters, and the
intended fix.

## 1. The egress allowlist is writable by the agent it constrains

`-Firewall` reads its per-project additions from `.vestibule/allowed-domains.txt`, which
sits in the project directory, which is bind-mounted read-write at `/work`. The agent can
append to the list that constrains it. The widening takes effect next session rather than
immediately, and it shows up in `git diff`, but both of those are detections that depend
on someone looking rather than controls.

`init-firewall.sh` documents the situation in a comment and names the escape: point
`AGENT_ALLOWLIST` at a read-only mount outside the workspace. That was never wired up.

**The trap in the obvious fix.** Binding the same file a second time as `:ro` changes
nothing. Both paths address the same host bytes and `/work` is still read-write, so the
agent edits it through the workspace and the read-only mount serves the edited content on
the next start. The mount mode is not the problem; the file living inside the mounted
project is.

**The fix.** Split the file in two, and mount only one of them:

- `.vestibule/allowed-domains.txt` stays in the repository as a *proposal*: versioned,
  reviewable, travelling with a clone, and still the file a person edits.
- `%LOCALAPPDATA%\vestibule\allowlists\<project>.txt` is the *adopted* policy. Only this
  one is ever mounted, read-only, at `/etc/vestibule/allowed-domains.txt`, with
  `AGENT_ALLOWLIST` pointing at it. `%LOCALAPPDATA%\vestibule\` is already established as
  host-only state by the session log, for the same reason.
- On launch, `agent` compares the two. Identical, it proceeds silently. Different, it
  prints the diff and refuses to start until the change is accepted, interactively or
  with `-AcceptAllowlist`.

The agent keeps write access to the proposal and loses the ability to make it take
effect. A widening becomes something you cannot start a session without seeing, instead
of something you may notice in a later diff.

Add `-Allow host1,host2` alongside it for the one-off case: session-scoped additions
passed by environment variable, nothing written to disk.

**Two things it touches.**

- `<project>` should key on a hash of the full path rather than the directory leaf. The
  leaf key is already shared with the home volume, where two repositories both named
  `api` collide; an adopted allowlist would inherit that.
- The devcontainer path runs `init-firewall.sh` from `postStartCommand` with no launcher
  in front of it, so it has nowhere to run the comparison. It likely has to use the
  adopted file only, and fail closed when none exists.

Largely superseded by item 9 if the egress proxy lands, since policy would then live in
the proxy rather than in a file the container reads. Worth doing regardless: the proxy is
a much larger change, and this is open until it ships.

## 2. Policy is imperative rather than declarative

The runtime half of this design is declarative: a Dockerfile, reviewable as a diff. The
policy half is not. `agent.ps1` computes the security posture at launch by assembling a
`docker run` command from strings, so there is no schema, nothing validates the result,
and the posture cannot be read without mentally executing a script that branches.

Four consequences:

- **No validation.** A malformed mount such as `-v "pwd:/work"` is still a well-formed
  docker command: it creates an empty volume and mounts it. A schema rejects that; a
  string builder cannot.
- **Two implementations of one policy.** `agent.ps1` and `template/devcontainer.json`
  express the same posture twice, so any change has to be made in both or they diverge.
- **The policy language is a hazard.** Case-insensitive `-replace`, positional parameter
  binding and quote mangling on the way to a native command are all failure modes
  originating in PowerShell rather than in the design.
- **Nothing compares the result to the claim.** No step checks the rendered command
  against the posture the README describes.

What mitigates this today is `verify.ps1`, which checks after the fact rather than
before: it asserts the posture the container actually has instead of trusting the script
that produced it. It runs automatically after every build, from both `install.ps1` and
`agent -Build`, which is where the thing it checks changes. It does not run per session,
so a posture assembled from flags at launch is still unvalidated.

Two structural mitigations narrow where a divergence can originate: every `-v` is
assembled in one block rather than accumulated across the function, and the startup
readout is parsed back out of the assembled arguments rather than restated per branch.
Neither is validation.

**The fix.** Move the posture into data, one `policy.psd1` or JSON holding mounts,
capabilities, network and limits, and have both launchers render it rather than restate
it. `agent.ps1` becomes a controller, `template/devcontainer.json` becomes generated
output, and `verify.ps1` asserts the rendered result matches the declared policy. One
source of truth, reviewable as a diff, structurally unable to drift.

Worth weighing against scale: a policy bug here reaches one laptop, where the same
weakness in a multi-tenant deployment reaches every tenant. Imperative policy with a
strong post-hoc check is defensible at this size, but only while the check is taken
seriously, and it should be a stated choice rather than an implicit one.

## 3. Observability of behaviour

Configuration and outcome are recorded host-side by both launchers, and `agent` prints
what changed in the working tree as a session ends. What is still missing is behaviour.

- **Blocked attempts are dropped silently**, so "never tried" and "tried forty times and
  was stopped" produce identical output. `-j LOG` before the DROP policy, rate-limited,
  would fix this, but the LOG target writes to the kernel ring buffer, which is shared
  across the whole VM and not namespaced. Containers cannot read it (`CAP_SYSLOG`), so
  entries mix and the read path is `wsl -d docker-desktop -- dmesg` on the host. Workable
  with a project-tagged prefix; the fiddliest of the remaining pieces.
- **iptables rule counters** are free and unread. `iptables -L -v -n` already counts
  packets and bytes per rule, readable on a running session with
  `docker exec --user root`. A per-session accepted-versus-dropped summary is about
  twenty lines.

Both only apply when `-Firewall` is on, which is the minority case.

What neither gives is a record of *what ran*. Process auditing needs
`CAP_AUDIT_CONTROL`, `CAP_SYS_PACCT` or eBPF, all excluded by `--cap-drop=ALL`, which is
the right trade. Syscall-level visibility is genuinely a tier-2 property.

## 4. Host network services are reachable by default

Docker Desktop resolves `host.docker.internal` inside every container, so a session can
reach anything the host has listening. Verified on a default Windows install: **SMB on
445 is reachable** from a vestibule container with all capabilities dropped and no socket
mounted. Not an escape by itself, but a route to host files that the mount list does not
model, and the README's central claim is that the mount list *is* the policy.

No cheap default fix is known, which is why this is open rather than done:

- `--add-host host.docker.internal:127.0.0.1` overrides the name but not the address, so
  it is cosmetic.
- `--internal` on the network removes all egress, not just host reach.
- A gateway-deny iptables rule needs `NET_ADMIN`, which the default posture drops.

Enabling property 3 closes it properly. The firewall is default-deny (`-P OUTPUT DROP`
plus an allowlist), so the host gateway is dropped like any other unlisted destination,
on both address families. The IPv6 policy covers it a second time.

That is a real fix rather than a workaround, but it costs `NET_ADMIN`, and the README
argues that dropping every capability is worth more than filtering destinations. So
closing this means reversing that trade for the session. `agent -NoNetwork` closes it
without the capability, at the cost of all egress. What is missing is an option that
removes host reach while keeping both the capability drop and normal outbound access.

Worth investigating: whether a rootless or user-namespaced configuration removes host
reachability without giving capabilities back.

## 5. `template/devcontainer.json` assumes Windows

```jsonc
"source=${localEnv:USERPROFILE}/.claude/CLAUDE.md"
```

`USERPROFILE` does not exist on macOS or Linux, so the expression resolves to an empty
string and the mount source becomes `/.claude/CLAUDE.md`. Docker then creates an empty
*directory* at the filesystem root rather than erroring, and preferences silently do not
load.

Confined to non-Windows hosts, which are not yet supported. The fix is what `agent.ps1`
already does: resolve the real path at generation time and bake it in, dropping
`localEnv` entirely. Blocks item 7.

## 6. Continuous integration

The build is not exercised from a clean checkout. Validation so far has run against a
warm Docker cache, so a bad digest pin would not surface.

Two jobs, because Windows runners cannot run Linux containers:

- **`ubuntu-latest`**: build the image, run the image and firewall checks under `pwsh`.
  Real coverage of the security-relevant half.
- **`windows-latest`**: parse-check the four scripts, assert `PositionalBinding` is off.
  No Docker.

The `PositionalBinding` guard must read `agent.ps1` directly rather than the loaded
function, since resolving `agent` in a shell can bind the script file instead.

Still needs an `-ImageOnly` switch on `verify.ps1` to skip the one remaining
profile-dependent check. Note that this validates the image, not the launcher on its
actual target platform, and the README should say so rather than implying a green badge
means more than it does.

## 7. macOS support

The image needs no change: the pinned digests are OCI indexes carrying arm64, so they
resolve natively on Apple Silicon.

- `agent.sh` and `install.sh` (zsh, guarded source line). Simpler than the PowerShell
  versions: no positional-binding trap, no quote mangling, no BOM.
- Generalise section 1, which is written Windows-first and names WSL2 throughout.
- Blocked on item 5.

GitHub's macOS runners cannot run Docker, so this will be verified by hand rather than by
CI. The README should say that rather than implying parity.

## 8. Provider endpoints out of the firewall defaults

`init-firewall.sh` bakes in Anthropic endpoints alongside the package registries. Once a
second harness is in regular use, provider hosts belong in the per-project allowlist so
the defaults do not silently grant reach to providers nobody is using.

## 9. Egress proxy

The real fix for property 3. A forward proxy doing SNI or Host filtering, with the
container given no direct route, replaces address-based filtering with hostname-based.
That closes the CDN problem: `github.com` and an arbitrary host on the same edge address
stop being indistinguishable.

Structure: agent container on an `--internal` network with the proxy; proxy dual-homed
with real egress. The container cannot bypass it because no other route exists, so the
`HTTPS_PROXY` variable is a convenience rather than the control.

Also delivers most of item 3 for free, since a proxy produces an access log by
construction.

## 10. Detached sessions

`agent` runs attached, so closing the terminal stops the container and takes every tmux
pane with it. A `-Detach` switch would start the container with a long-lived main process
and `exec` into it, making overnight runs survive a closed terminal. Means dropping
`--rm` for those sessions, so cleanup becomes manual.

## 11. Debian trixie

The base is still bookworm, now oldstable. Moving changes `iptables`, `ipset` and `tmux`
versions simultaneously, which is why it is its own change rather than a rider on the
Python bump. The firewall checks cover the resulting regression surface.

## 12. Single-dash harness flags collide with parameter binding

```powershell
agent bash -c 'echo hi'
# Parameter cannot be processed because the parameter name 'c' is ambiguous.
# Possible matches include: -Cpus -ContextDir -Command.
```

PowerShell resolves parameter names before `ValueFromRemainingArguments` collects what is
left, so a single-dash flag intended for the harness is matched against `agent`'s own
parameters first. `PositionalBinding = $false` does not help: it governs positional
binding, not named binding.

Double-dash flags are unaffected, so `agent claude --resume` and
`agent claude --dangerously-skip-permissions` pass through intact. The gap is short
flags, where `bash -c` and `sh -c` are the common cases.

`agent -Command bash,'-c','echo hi'` works today. A real fix means either the `--%`
stop-parsing token, which changes how the rest of the line is quoted, or renaming
parameters until no short flag is ambiguous, which cannot cover flags a harness has not
shipped yet.

Evidence that renaming is the losing option: adding `-Settings` on 2026-08-31 made `-S`
ambiguous, where it had resolved uniquely to `-SkipVerify` before. Nothing common passes
`-S` to a harness, so the practical cost was nil, but the direction is one-way. Every
parameter `agent` gains shrinks the space of unambiguous short flags, and the set of
flags to stay clear of is defined by harnesses that have not shipped yet. Renaming can
only ever be correct for the parameters and harnesses that exist on the day it is done.
That leaves `--%`.

## 13. One container per project

`--name agent-<project>` is derived from the directory, so a second session on the same
project fails on a name collision and surfaces docker's own error rather than anything
`agent` wrote. The session record marks that case correctly, with exit 125 and a null
outcome, but the launcher neither explains it nor offers to attach.

Two directions, and they are different features. Detect the collision and offer
`docker exec` into the running container, which is the multi-window case from item 10. Or
suffix the name so parallel containers coexist, which costs one home volume per suffix
and gives up the shared-login property.

Low priority: `docs/parallel-agents.md` already covers several agents on one project
through tmux and worktrees, which is the case this would otherwise serve.

## 14. No way to compare harnesses on the same problem

`-Settings` namespaces configuration by harness: `claude\` is Claude Code's, a future
`opencode\` would be opencode's, and the repository root holds what they share. That makes
it possible to carry two harnesses' configuration in one settings repository and point
sessions at either. What is missing is everything that would make a comparison between
them trustworthy.

Most of the substrate already exists for another reason. `sessions.jsonl` records
`command`, `exitCode`, `seconds`, `headBefore`/`headAfter`, `changed[]`, `image`,
`network`, `firewall` and `settings`, host-side and unreachable from the container that
produced them. That is configuration and outcome per run, which is the right granularity
for a comparison. It was chosen because behaviour needs process auditing and capabilities
this design drops, so the fit is a coincidence rather than a plan.

**The blocker is the home volume.** `agent-home-<project>` is keyed on the directory leaf,
so two harnesses run against the same project share one volume: the same login, the same
transcripts, the same accumulated state. Sequential runs contaminate each other silently,
which makes run order a variable and the comparison worthless.

`-Isolated` gives a fresh scratch volume but deliberately mounts nothing from the machine,
settings included, so it cannot serve this. What is needed is a posture that does not
exist: project mounted, settings mounted, **fresh home volume per run**. Suffixing the
volume name is most of it, and it overlaps with item 13's second direction.

**The confound, which no amount of tooling removes.** Settings cannot be held constant
across harnesses, because the settings *are* each harness's mechanisms. `commit-gate.sh`
is a Claude Code `PreToolUse` hook; a harness without an equivalent runs ungated against a
gated one. So a run compares harness-plus-its-configuration, not the harness. That is
arguably the honest unit, since nobody runs a harness naked, but any write-up has to say
which question it answered.

Judging needs a task that can be re-run and a test that says whether it was solved.
`changed[]` and the HEAD pair say something happened, not whether it was right. A repo's
own test suite is the natural judge and is harness-independent.

Depends on item 10 for unattended runs and overlaps item 13 on naming. Lower priority than
anything above it: this is a capability rather than a gap, and the four items at the top
are defects in claims the README already makes.

## 15. Launcher language

`agent.ps1` is PowerShell. Python would remove item 12 outright: argparse does not
prefix-match, so `agent bash -c 'x'` works and no parameter added later can collide with a
harness flag. The mount list would also stop being strings. Today the readout re-parses `-v`
specs with a regex, and a readout restated rather than derived has already drifted once,
reporting nothing mounted while a bind still applied; typed mount objects rendered into both
the docker arguments and the readout make that class of drift impossible rather than guarded.
`Get-AgentScopeRefusal` is already written as a pure function so `verify.ps1` can assert it
against synthetic paths, which is a unit test waiting for a framework.

Against: PowerShell 5.1 is present on every Windows machine and Python is not, which is a real
regression in install friction for a Windows-first tool. And 28% of `agent.ps1` is comment,
each one recording an incident. The risk is not the porting time, which does not matter here.
It is transcribing 212 lines of hard-won prose and losing the reasoning, which would not be
noticed for months.

If it happens, `verify` ports first and must pass against the existing PowerShell launcher
before the new launcher is written. The checks are already the specification, so equivalence
becomes demonstrated rather than hoped for. Comments port before code: a comment that does not
survive the move takes its incident with it.

Sequencing. `-Detach` is small and touches none of what a rewrite improves, so it should land
in PowerShell either way. `-Multi` is exactly the mount-list assembly a rewrite most improves,
so it should be written once, in whichever language is being kept. That makes the decision due
before `-Multi`, not after.
