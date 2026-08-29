# Debian bookworm + CPython 3.13 (supported to Oct 2029).
#
# Not mcr.microsoft.com/devcontainers/*: those carry third-party apt sources this image
# never uses (yarn's ships a signing key the image lacks, breaking `apt-get update`).
#
# Every external layer is digest-pinned: a floating tag means the bytes you audited are
# not the bytes you get tomorrow. The trade is that security updates stop arriving, so
# re-pin periodically:
#   docker pull python:3.13-slim-bookworm
#   docker image inspect python:3.13-slim-bookworm --format '{{index .RepoDigests 0}}'
#
# This interpreter does not constrain your projects: uv manages a per-project Python and
# virtualenv of its own on the home volume (see UV_PROJECT_ENVIRONMENT below). It serves
# ad-hoc scripting only, so it need only be current.
FROM python:3.13-slim-bookworm@sha256:cbd229d7b9bd041012af758ce5ffd807a6518d76493ce9035d208f1db9ceff1e

# Debian slim sets no locale, leaving LC_CTYPE=POSIX. tmux then treats bytes as
# single-byte and mangles multi-byte UTF-8, so box-drawing and block characters in agent
# TUIs render as garbage inside tmux but correctly outside it. C.UTF-8 is built into
# glibc and needs no locale generation.
ENV LANG=C.UTF-8

# Debian's signed repos only; no third-party apt sources.
#   iptables/ipset/dnsutils  init-firewall.sh needs these
#   ripgrep/jq               agent tooling; without rg it falls back to slow greps
#   tmux                     multiplexing inside the container (see README)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git sudo \
      iptables ipset dnsutils \
      ripgrep jq tmux \
 && rm -rf /var/lib/apt/lists/*

# Node only because agent harnesses ship on npm. A pinned layer rather than an apt repo
# or a live installer. Copied selectively: all of /usr/local would clobber Python, which
# also lives there.
COPY --from=node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5 /usr/local/bin/node /usr/local/bin/node
COPY --from=node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5 /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

COPY --from=ghcr.io/astral-sh/uv:0.8.13@sha256:4de5495181a281bc744845b9579acf7b221d6791f99bcc211b9ec13f417c2853 /uv /uvx /usr/local/bin/

# Where uv puts a project's virtualenv. Without it uv defaults to .venv beside the
# pyproject.toml, which for a bind-mounted project writes a Linux venv onto the host:
# useless there (wrong-platform binaries, absolute paths that resolve only inside the
# container) and destructive when the host already keeps an environment by that name.
# /home/dev is the per-project home volume from agent.ps1, so the environment survives
# container restarts and stays private to one project.
#
# In the image, not ~/.bashrc: bashrc is read only by interactive shells, so an agent
# running `uv sync` non-interactively would miss it, write to the bind mount, and hit
# the case above.
ENV UV_PROJECT_ENVIRONMENT=/home/dev/.venv

# Which harnesses the image contains. Space-separated npm packages:
#   agent -Build -BuildArg "HARNESSES=@anthropic-ai/claude-code opencode-ai"
#
# Installed as root so the agent cannot update itself, and so `docker history` shows
# exactly what went in. That matters: harnesses have shipped RCE bugs.
#
# The firewall's built-in allowlist names Anthropic endpoints only; a harness using
# another provider needs that host in its project .vestibule/allowed-domains.txt.
ARG HARNESSES="@anthropic-ai/claude-code"
RUN npm install -g ${HARNESSES} && npm cache clean --force

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod 0755 /usr/local/bin/init-firewall.sh

# /etc, not the home directory: the home volume is seeded from the image once and never
# updated. tmux reads /etc/tmux.conf then ~/.tmux.conf, so projects can still override.
COPY tmux.conf /etc/tmux.conf

ARG USERNAME=dev

# env_keep is load-bearing: sudo resets the environment, discarding AGENT_ALLOWLIST and
# leaving the firewall on its built-in domains while still reporting success.
#
# /work must exist here AND be owned by the user. An empty named volume inherits
# ownership from the image path; with no such directory it is created root-owned and
# `agent -Isolated` cannot write to it. Bind mounts take ownership from the host, so
# only the isolated path is affected.
RUN useradd --create-home --shell /bin/bash ${USERNAME} \
 && printf '%s\n%s\n' \
      'Defaults!/usr/local/bin/init-firewall.sh env_keep += "AGENT_ALLOWLIST"' \
      "${USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
      > /etc/sudoers.d/10-init-firewall \
 && chmod 0440 /etc/sudoers.d/10-init-firewall \
 && mkdir -p /work \
 && chown ${USERNAME}:${USERNAME} /work

USER ${USERNAME}

# Same ownership-inheritance reason as /work above.
RUN mkdir -p /home/${USERNAME}/.claude /home/${USERNAME}/.cache/uv
