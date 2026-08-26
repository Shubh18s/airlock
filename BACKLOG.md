# Backlog

Known gaps, roughly in priority order. Published rather than kept private because the
README claims specific properties, and where those claims are weak is worth stating.

## 1. Observability

Currently the weakest thing about the design, and the one that undercuts its own claims.
Blocked network attempts are dropped silently, so there is no way to distinguish "the
agent never tried anything unusual" from "the agent tried forty times and was stopped".
A control that cannot show it worked is hard to rely on.

Four steps, cheapest first:

- **iptables rule counters.** `iptables -L -v -n` already counts packets and bytes per
  rule. Reading them before the container exits costs nothing and gives a per-session
  egress summary. The counters exist whether or not anyone looks.
- **`-j LOG` before the DROP policy**, rate-limited. Turns blocked attempts into kernel
  log lines readable with `dmesg`.
- **Host-side session manifest.** `agent.ps1` appends one record per session outside the
  container: timestamp, project, image digest, mount list, network, allowlist hash,
  duration, exit code. This is the only artefact a compromised session cannot edit, which
  is what makes it worth more than anything logged from inside.
- **`git status --short` on exit**, summarising what changed in the project.

What none of this gives is a record of *what ran*. Process-level auditing needs
`CAP_AUDIT_CONTROL`, `CAP_SYS_PACCT` or eBPF, all excluded by `--cap-drop=ALL`, which is
the right trade. Syscall-level visibility is genuinely a tier-2 property.

## 2. Host network services are reachable by default

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

## 3. `template/devcontainer.json` assumes Windows

```jsonc
"source=${localEnv:USERPROFILE}/.claude/CLAUDE.md"
```

`USERPROFILE` does not exist on macOS or Linux, so the expression resolves to an empty
string and the mount source becomes `/.claude/CLAUDE.md`. Docker then creates an empty
*directory* at the filesystem root rather than erroring, and preferences silently do not
load.

Latent today because nothing but Windows has run it. The fix is what `agent.ps1` already
does: resolve the real path at generation time and bake it in, dropping `localEnv`
entirely. Blocks item 5.

## 4. Continuous integration

Nothing has ever been built from a clean checkout. Everything so far was validated
against one machine's Docker cache, so a bad digest pin would not surface.

Two jobs, because Windows runners cannot run Linux containers:

- **`ubuntu-latest`** -- build the image, run the image and firewall checks under `pwsh`.
  Real coverage of the security-relevant half.
- **`windows-latest`** -- parse-check the three scripts, assert `PositionalBinding` is
  off. No Docker.

Needs an `-ImageOnly` switch on `verify.ps1` to skip the profile-dependent checks. Note
that this validates the image, not the launcher on its actual target platform, and the
README should say so rather than implying a green badge means more than it does.

## 5. macOS support

The image needs no change -- the pinned digests are OCI indexes carrying arm64, so they
resolve natively on Apple Silicon.

- `agent.sh` and `install.sh` (zsh, guarded source line). Simpler than the PowerShell
  versions: no positional-binding trap, no quote mangling, no BOM.
- Generalise section 1, which is written Windows-first and names WSL2 throughout.
- Blocked on item 3.

GitHub's macOS runners cannot run Docker, so this will be verified by hand rather than by
CI. The README should say that rather than implying parity.

## 6. Provider endpoints out of the firewall defaults

`init-firewall.sh` bakes in Anthropic endpoints alongside the package registries. Once a
second harness is in regular use, provider hosts belong in the per-project allowlist so
the defaults do not silently grant reach to providers nobody is using.

## 7. Egress proxy

The real fix for property 3. A forward proxy doing SNI or Host filtering, with the
container given no direct route, replaces address-based filtering with hostname-based.
That closes the CDN problem: `github.com` and an arbitrary host on the same edge address
stop being indistinguishable.

Structure: agent container on an `--internal` network with the proxy; proxy dual-homed
with real egress. The container cannot bypass it because no other route exists, so the
`HTTPS_PROXY` variable is a convenience rather than the control.

Also delivers most of item 1 for free, since a proxy produces an access log by
construction.

## 8. Detached sessions

`agent` runs attached, so closing the terminal stops the container and takes every tmux
pane with it. A `-Detach` switch would start the container with a long-lived main process
and `exec` into it, making overnight runs survive a closed terminal. Means dropping
`--rm` for those sessions, so cleanup becomes manual.

## 9. Debian trixie

The base is still bookworm, now oldstable. Moving changes `iptables`, `ipset` and `tmux`
versions simultaneously, which is why it is its own change rather than a rider on the
Python bump. The firewall checks would catch a regression, which they would not have
before those tests existed.
