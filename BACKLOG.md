# Backlog

Known gaps, roughly in priority order. Published rather than kept private because the
README claims specific properties, and where those claims are weak is worth stating.

## 1. Policy is imperative, and has drifted three times

The runtime half of this design is declarative: a Dockerfile, reviewable as a diff. The
policy half is not. `agent.ps1` computes the security posture at launch by assembling a
`docker run` command from strings, so there is no schema, nothing validates the result,
and the posture cannot be read without mentally executing a script that branches.

Four costs already paid here:

- **No validation.** `-v "pwd:/work"` was a well-formed docker command that silently
  created an empty volume and mounted it. A schema rejects that; a string builder cannot.
- **Two implementations, drifted three times.** `agent.ps1` and `template/devcontainer.json`
  express the same policy twice. The global `CLAUDE.md` mount, session recording, and the
  firewall mechanism have each been present in one and missing from the other.
- **The policy language fights back.** Case-insensitive `-replace` during a rename,
  positional binding rebuilding the image under the wrong tag, quoting mangled on the way
  to a native command. Three bugs originating in the language rather than the design.
- **Nothing compares the result to the claim.** No step checks the rendered command
  against the posture the README describes.

What mitigates this today is `verify.ps1`, which checks after the fact rather than
before: it asserts the posture the container actually has instead of trusting the script
that produced it. That is why it caught a dead firewall within an hour of existing. It runs
automatically after every build, from both `install.ps1` and `agent -Build`, which is
where the thing it checks changes. It does not run per session, so a posture assembled
from flags at launch is still unvalidated.

Two structural mitigations since: every `-v` is assembled in one block rather than
accumulated across the function, and the startup readout is parsed back out of the
assembled arguments rather than restated per branch. Neither is validation. Both narrow
where a divergence can originate, which is what allowed `-Isolated` to mount a home
volume, a shared cache and a host bind that no branch of the code appeared to grant.

**The fix.** Move the posture into data -- one `policy.psd1` or JSON holding mounts,
capabilities, network and limits -- and have both launchers render it rather than restate
it. `agent.ps1` becomes a controller, `template/devcontainer.json` becomes generated
output, and `verify.ps1` asserts the rendered result matches the declared policy. One
source of truth, reviewable as a diff, structurally unable to drift.

Worth weighing against scale: a policy bug here reaches one laptop, where the same
weakness in a multi-tenant deployment reaches every tenant. Imperative policy with a
strong post-hoc check is defensible at this size, but only while the check is taken
seriously, and it should be a stated choice rather than an accident of having started in
PowerShell.

## 2. Observability of behaviour

Configuration and outcome are now recorded host-side by both launchers, and `agent`
prints what changed in the working tree as a session ends. What is still missing is
behaviour.

- **Blocked attempts are dropped silently**, so "never tried" and "tried forty times and
  was stopped" produce identical output. `-j LOG` before the DROP policy, rate-limited,
  would fix this -- but the LOG target writes to the kernel ring buffer, which is shared
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

## 3. Host network services are reachable by default

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

That is a real fix, not a workaround -- but it costs `NET_ADMIN`, and the README argues
that dropping every capability is worth more than filtering destinations. So closing this
means reversing that trade for the session. `agent -NoNetwork` closes it without the
capability, at the cost of all egress. What is missing is an option that removes host
reach while keeping both the capability drop and normal outbound access.

Worth investigating: whether a rootless or user-namespaced configuration removes host
reachability without giving capabilities back.

## 4. `template/devcontainer.json` assumes Windows

```jsonc
"source=${localEnv:USERPROFILE}/.claude/CLAUDE.md"
```

`USERPROFILE` does not exist on macOS or Linux, so the expression resolves to an empty
string and the mount source becomes `/.claude/CLAUDE.md`. Docker then creates an empty
*directory* at the filesystem root rather than erroring, and preferences silently do not
load.

Latent today because nothing but Windows has run it. The fix is what `agent.ps1` already
does: resolve the real path at generation time and bake it in, dropping `localEnv`
entirely. Blocks item 6.

## 5. Continuous integration

Nothing has ever been built from a clean checkout. Everything so far was validated
against one machine's Docker cache, so a bad digest pin would not surface.

Two jobs, because Windows runners cannot run Linux containers:

- **`ubuntu-latest`** -- build the image, run the image and firewall checks under `pwsh`.
  Real coverage of the security-relevant half.
- **`windows-latest`** -- parse-check the four scripts, assert `PositionalBinding` is
  off. No Docker.

The `PositionalBinding` guard now reads `agent.ps1` directly rather than the loaded
function. Before that it resolved `agent` to the script file rather than the function and
reported a failure that was not real, which is precisely what this job would have hit.

Still needs an `-ImageOnly` switch on `verify.ps1` to skip the one remaining
profile-dependent check. Note
that this validates the image, not the launcher on its actual target platform, and the
README should say so rather than implying a green badge means more than it does.

## 6. macOS support

The image needs no change -- the pinned digests are OCI indexes carrying arm64, so they
resolve natively on Apple Silicon.

- `agent.sh` and `install.sh` (zsh, guarded source line). Simpler than the PowerShell
  versions: no positional-binding trap, no quote mangling, no BOM.
- Generalise section 1, which is written Windows-first and names WSL2 throughout.
- Blocked on item 4.

GitHub's macOS runners cannot run Docker, so this will be verified by hand rather than by
CI. The README should say that rather than implying parity.

## 7. Provider endpoints out of the firewall defaults

`init-firewall.sh` bakes in Anthropic endpoints alongside the package registries. Once a
second harness is in regular use, provider hosts belong in the per-project allowlist so
the defaults do not silently grant reach to providers nobody is using.

## 8. Egress proxy

The real fix for property 3. A forward proxy doing SNI or Host filtering, with the
container given no direct route, replaces address-based filtering with hostname-based.
That closes the CDN problem: `github.com` and an arbitrary host on the same edge address
stop being indistinguishable.

Structure: agent container on an `--internal` network with the proxy; proxy dual-homed
with real egress. The container cannot bypass it because no other route exists, so the
`HTTPS_PROXY` variable is a convenience rather than the control.

Also delivers most of item 2 for free, since a proxy produces an access log by
construction.

## 9. Detached sessions

`agent` runs attached, so closing the terminal stops the container and takes every tmux
pane with it. A `-Detach` switch would start the container with a long-lived main process
and `exec` into it, making overnight runs survive a closed terminal. Means dropping
`--rm` for those sessions, so cleanup becomes manual.

## 10. Debian trixie

The base is still bookworm, now oldstable. Moving changes `iptables`, `ipset` and `tmux`
versions simultaneously, which is why it is its own change rather than a rider on the
Python bump. The firewall checks would catch a regression, which they would not have
before those tests existed.

## 11. Single-dash harness flags collide with parameter binding

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

## 12. One container per project

`--name agent-<project>` is derived from the directory, so a second session on the same
project fails on a name collision and surfaces docker's own error rather than anything
`agent` wrote. The session record marks that case correctly, with exit 125 and a null
outcome, but the launcher neither explains it nor offers to attach.

Two directions, and they are different features. Detect the collision and offer
`docker exec` into the running container, which is the multi-window case from item 9. Or
suffix the name so parallel containers coexist, which costs one home volume per suffix
and gives up the shared-login property.

Low priority: `docs/parallel-agents.md` already covers several agents on one project
through tmux and worktrees, which is the case this would otherwise serve.
