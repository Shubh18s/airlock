#!/usr/bin/env bash
#
# Default-deny egress for the agent container.
#
# Runs as root on every container start (postStartCommand), which is after the image
# build but before you ever attach a shell, so the agent never executes with an
# unrestricted network. It must run on every start because iptables rules do not
# survive a container restart.
#
# Mechanism lives here (in the shared image). Policy is per project -- see ALLOWLIST_FILE.
#
set -euo pipefail

# Minimum needed for the agent to function at all. Kept deliberately tiny.
ALLOWED_DOMAINS=(
  api.anthropic.com          # Claude Code itself
  statsig.anthropic.com      # feature flags / config
  registry.npmjs.org         # npm
  pypi.org                   # uv metadata
  files.pythonhosted.org     # uv wheels
)

# Per-project additions, one domain per line, '#' comments allowed.
#
# This path sits inside the writable workspace, so the agent can append to it and widen
# its own policy. It takes effect only next session (the agent cannot restart the
# container) and shows up in `git diff`. To remove the possibility, point
# AGENT_ALLOWLIST at a read-only mount outside the workspace.
#
# The default must match the workspace mount point used by agent.ps1. A mismatch fails
# SILENTLY: the file is not found and only the built-in domains apply.
ALLOWLIST_FILE="${AGENT_ALLOWLIST:-/work/.vestibule/allowed-domains.txt}"

if [[ -f "$ALLOWLIST_FILE" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"                       # strip comments
    line="$(tr -d '[:space:]' <<<"$line")"   # strip whitespace
    [[ -n "$line" ]] && ALLOWED_DOMAINS+=("$line")
  done < "$ALLOWLIST_FILE"
fi

ipset destroy allowed 2>/dev/null || true
ipset create allowed hash:ip

for domain in "${ALLOWED_DOMAINS[@]}"; do
  # The allowlist is resolved and enforced over IPv4 only. IPv6 is handled by being
  # shut off entirely below, rather than left to chance.
  for ip in $(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u); do
    ipset add allowed "$ip" -exist
  done
done

iptables -F OUTPUT
iptables -F INPUT

# Loopback, and return traffic on connections the container opened itself.
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS to Docker's embedded resolver. Without this nothing above resolves.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

iptables -A OUTPUT -m set --match-set allowed dst -j ACCEPT

iptables -P OUTPUT DROP
iptables -P INPUT  DROP

# IPv6: shut off, not filtered.
#
# The allowlist above is IPv4-only, so a routable v6 path would make every rule
# above a no-op for v6 traffic -- silently, while the log line still reports an
# active allowlist. Denying outright makes the failure mode "IPv6 does not work",
# which is diagnosable, rather than "IPv6 is unfiltered", which is not.
#
# To allow v6 egress instead, mirror the ipset logic here with `getent ahostsv6`
# and `ipset create allowed6 hash:ip family inet6`.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -F INPUT  2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
  if ip6tables -P OUTPUT DROP 2>/dev/null && ip6tables -P INPUT DROP 2>/dev/null; then
    v6_state="denied"
  else
    # Kernel built without IPv6, or the module is unavailable. Nothing to filter,
    # but say so rather than implying a policy was applied.
    v6_state="unavailable (no policy set)"
  fi
else
  v6_state="ip6tables MISSING -- v6 unfiltered if routable"
  echo "WARNING: ip6tables not found; IPv6 cannot be denied" >&2
fi

printf 'egress allowlist active -- %d domains, %d addresses; IPv6 %s\n' \
  "${#ALLOWED_DOMAINS[@]}" "$(ipset list allowed | grep -cE '^[0-9]+\.')" "$v6_state"
