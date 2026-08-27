# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: **Security -> Report a vulnerability** on
this repository. That keeps the report private until there is a fix.

Please do not open a public issue for anything that would give someone a working attack
before it is patched.

This is a one-person project with no service-level commitment. Expect a reply in days
rather than hours, and a fix on a best-effort basis. If a report is valid and I cannot
fix it quickly, I will document it in the README's limits section rather than leave it
unstated.

## Supported versions

`main` only. There are no releases, and no fixes are backported.

## What is in scope

The most valuable report is simple: **a control that does not do what the README says it
does.** The README makes specific claims; if one of them is false, that is a
vulnerability even when the underlying tool behaves correctly.

Two real examples, both fixed, both of which silently disabled a documented control:

- A byte-order mark before the shebang in `init-firewall.sh` meant it ran under `/bin/sh`
  and aborted, so the firewall was inert while appearing installed.
- `sudo` stripped `AGENT_ALLOWLIST`, so the per-project allowlist documented in the
  README was silently ignored and only the built-in domains applied.

Also in scope:

- A way to reach a host path that is not on the mount list
- A way for one project's session to reach another's container, volumes, or credentials
- A way to obtain the host's credentials from inside a container
- Any way the container is weaker than [docs/design.md](docs/design.md) claims

## What is not in scope

These are documented behaviours, not bugs. They are described in full under
[What it does not do](docs/design.md#what-it-does-not-do):

- **The mounted project is fully readable and writable**, including any `.env` inside it.
  The agent has to be able to edit that directory.
- **Egress is unrestricted by default.** The allowlist is opt-in (property 3). A session
  reaching an arbitrary host in the default configuration is expected.
- **A kernel exploit defeats this tier.** Containers share one kernel (property 1).
- **Credentials you give the agent are readable by it.** Nothing can protect a key from
  code that legitimately needs that key (property 4).
- **Almost nothing is recorded.** Blocked network attempts are dropped silently.

Please report vulnerabilities in the agent harnesses themselves, in Docker, or in WSL2 to
those projects rather than here.

## Scope of the threat model

This is tier 1: process containment on a shared kernel, for one person running a coding
agent against their own code on their own laptop. It is not a multi-tenant sandbox and
does not aim to run untrusted third-party code. Reports assuming that stronger model are
welcome as discussion, but will be answered with the same reasoning rather than a fix.
