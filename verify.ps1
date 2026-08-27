<#
  Checks that the image and launcher actually work.

      .\verify.ps1

  Every check here exists because something went wrong once. Runs automatically after a
  build, from install.ps1 and `agent -Build`; run it by hand when a session behaves oddly,
  before you start debugging your own code.
#>
[CmdletBinding()]
param(
    [string] $Image = 'vestibule:1'
)

# Set explicitly rather than inherited. Invoked with & from a caller that set 'Stop',
# as `agent` does, docker's ordinary stderr becomes a terminating error, so every check
# that shells out reports a failure that never happened.
$ErrorActionPreference = 'Continue'

$script:Failures = 0

function Test-Item {
    param(
        [string]   $Name,
        [scriptblock] $Check,   # should return $true / $false
        [string]   $Why         # shown on failure
    )
    Write-Host ("  {0,-42}" -f $Name) -NoNewline
    $ok = $false
    try { $ok = & $Check } catch { $ok = $false }
    if ($ok) {
        Write-Host "PASS" -ForegroundColor Green
    }
    else {
        Write-Host "FAIL" -ForegroundColor Red
        if ($Why) { Write-Host "      $Why" -ForegroundColor DarkGray }
        $script:Failures++
    }
}

Write-Host ""
Write-Host "vestibule checks" -ForegroundColor Cyan
Write-Host ""

Test-Item "docker responds" {
    docker version --format '{{.Server.Version}}' | Out-Null
    $LASTEXITCODE -eq 0
} "Docker Desktop is not running."

Test-Item "image $Image exists" {
    [bool](docker images -q $Image)
} "Build it: docker build -t $Image .\image"

# The rest need the image, so stop if it is missing.
if ($script:Failures -gt 0) {
    Write-Host ""
    Write-Host "$($script:Failures) check(s) failed." -ForegroundColor Red
    exit 1
}

Test-Item "runs as non-root" {
    (docker run --rm $Image id -u) -eq '1000'
} "Container should run as uid 1000, not root."

Test-Item "/work exists and is user-writable" {
    docker run --rm $Image sh -c 'test -w /work' | Out-Null
    $LASTEXITCODE -eq 0
} "A named volume mounted here would be root-owned and 'agent -Isolated' would fail."

Test-Item "named volume at /work is writable" {
    docker volume rm agent-verify-tmp 2>$null | Out-Null
    docker run --rm -v agent-verify-tmp:/work -w /work $Image sh -c 'touch probe' | Out-Null
    $ok = $LASTEXITCODE -eq 0
    docker volume rm agent-verify-tmp 2>$null | Out-Null
    $ok
} "This is the exact failure mode of 'git clone' in an isolated session."

Test-Item "tooling present" {
    docker run --rm $Image sh -c 'command -v git tmux rg jq uv python3 claude >/dev/null' | Out-Null
    $LASTEXITCODE -eq 0
} "One of git/tmux/rg/jq/uv/python3/claude is missing from the image."

Test-Item "tmux config installed and valid" {
    docker run --rm $Image sh -c 'test -f /etc/tmux.conf && tmux -f /etc/tmux.conf start-server \; kill-server' | Out-Null
    $LASTEXITCODE -eq 0
} "tmux could not parse /etc/tmux.conf, or the terminfo entry it names is absent."

Test-Item "capabilities dropped (sudo unavailable)" {
    docker run --rm --cap-drop=ALL --security-opt=no-new-privileges $Image sh -c 'sudo -n true 2>/dev/null' | Out-Null
    $LASTEXITCODE -ne 0
} "sudo should FAIL under --cap-drop=ALL. If it succeeds, hardening is not applied."

# A socket connect, not an HTTP request: reachability is the question, and an HTTP 4xx
# would exit non-zero while proving the network works.
Test-Item "outbound network reachable" {
    docker run --rm $Image python3 -c "import socket;socket.create_connection(('api.anthropic.com',443),timeout=10)" 2>$null | Out-Null
    $LASTEXITCODE -eq 0
} "No egress. Check Docker's network or a corporate proxy."

Test-Item "per-project network can be created" {
    docker network create agent-verify-tmp | Out-Null
    $ok = $LASTEXITCODE -eq 0
    docker network rm agent-verify-tmp 2>$null | Out-Null
    $ok
} "Address pools may be exhausted. Try: docker network prune"

# The allowlist is opt-in and needs NET_ADMIN, so a plain session never exercises it,
# leaving the one piece of active defence untested. Four constraints, each from a test
# that once failed for the wrong reason:
#
#   - /dev/tcp, not curl. Neither curl nor wget is in the image, and a missing binary
#     makes the "blocked" test pass on 'command not found', which is a false positive.
#   - A literal IP, not a domain. CDN-fronted names resolve differently at firewall time
#     and probe time, so a domain-based test fails intermittently.
#   - `timeout` on every probe. Rules DROP rather than REJECT, so a blocked connect hangs
#     until TCP gives up.
#   - Mount the script, do not pass it as an argument. PowerShell rewrites quotes on the
#     way to a native command and this needs both kinds.
#
# The container prints its own verdicts; PowerShell only reads them.
$fwLines = @(
    '#!/usr/bin/env bash'
    'IP=$(getent ahostsv4 example.com | head -1 | cut -d" " -f1)'
    'echo "$IP" > /tmp/allow'
    'OUT=$(sudo /usr/local/bin/init-firewall.sh 2>&1)'
    'case "$OUT" in *"IPv6 denied"*|*"IPv6 unavailable"*) echo V6_OK ;; *) echo V6_BAD ;; esac'
    'case "$OUT" in *"6 domains"*) echo LIST_READ ;; *) echo LIST_IGNORED ;; esac'
    'if timeout 8 bash -c "exec 3<>/dev/tcp/$IP/443" 2>/dev/null; then echo ALLOW_OK; else echo ALLOW_BLOCKED; fi'
    'if timeout 8 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>/dev/null; then echo DENY_LEAK; else echo DENY_OK; fi'
)
# LF endings and no BOM: CRLF breaks the shebang, and a BOM breaks it differently.
$fwFile = Join-Path ([System.IO.Path]::GetTempPath()) 'vestibule-fw-probe.sh'
[System.IO.File]::WriteAllText($fwFile, ($fwLines -join "`n") + "`n",
                               (New-Object System.Text.UTF8Encoding($false)))

$fw = (docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW `
        -e AGENT_ALLOWLIST=/tmp/allow `
        -v "${fwFile}:/probe.sh:ro" $Image bash /probe.sh 2>&1) -join ' '
Remove-Item $fwFile -ErrorAction SilentlyContinue

Test-Item "firewall: denies IPv6" {
    $fw -match 'V6_OK'
} "IPv6 left unfiltered. If the container ever gets a v6 route, the allowlist is a no-op."

Test-Item "firewall: reads the per-project allowlist" {
    $fw -match 'LIST_READ'
} "AGENT_ALLOWLIST was ignored -- check the sudo env_keep line in the Dockerfile."

Test-Item "firewall: allowlisted address reachable" {
    $fw -match 'ALLOW_OK'
} "An allowlisted address was unreachable after applying the firewall."

Test-Item "firewall: non-allowlisted address blocked" {
    $fw -match 'DENY_OK'
} "An address NOT on the allowlist was still reachable. The allowlist is not enforcing."

# -CommandType Function is required. Run from the repo directory, a bare
# `Get-Command agent` resolves to agent.ps1 itself as an ExternalScript, so this passed
# whether or not the profile was ever wired.
Test-Item "'agent' command is loaded" {
    [bool](Get-Command agent -CommandType Function -ErrorAction SilentlyContinue)
} "Run .\install.ps1, then open a new shell (or: . `$PROFILE)."

# Regression guard. `agent claude` once bound 'claude' to -Image, failed to find that
# image, rebuilt the whole thing under that tag, and never ran the agent.
#
# Read the file, not the session. The same ExternalScript resolution above reported the
# script's own binding rather than the function's, so this failed whenever verify ran
# without the profile loaded: by hand from the repo, or in CI, which is precisely where
# a regression guard has to work.
Test-Item "arguments do not bind positionally" {
    $path = Join-Path $PSScriptRoot 'agent.ps1'
    $ast  = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $fn   = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'agent'
    }, $true)
    if (-not $fn) { return $false }

    $ok = $false
    foreach ($attr in $fn.Body.ParamBlock.Attributes) {
        if ($attr.TypeName.Name -ne 'CmdletBinding') { continue }
        foreach ($na in $attr.NamedArguments) {
            if ($na.ArgumentName -eq 'PositionalBinding' -and
                $na.Argument.Extent.Text -match '\$false') { $ok = $true }
        }
    }
    $ok
} "agent must declare [CmdletBinding(PositionalBinding = `$false)], or 'agent claude' silently rebuilds the image."

Write-Host ""
if ($script:Failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Failures) check(s) failed." -ForegroundColor Red
exit 1
