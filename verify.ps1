<#
  Checks that the image and launcher work.

      .\verify.ps1

  Each check covers a failure seen in practice. Runs automatically after a build, from
  install.ps1 and `agent -Build`. Run it by hand when a session behaves oddly, before
  debugging your own code.
#>
[CmdletBinding()]
param(
    [string] $Image = 'vestibule:1'
)

# Set explicitly, not inherited. Called with & from a caller using 'Stop', as `agent`
# does, docker's ordinary stderr becomes a terminating error and every check that shells
# out reports a failure that never happened.
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

# A socket connect, not an HTTP request: an HTTP 4xx would exit non-zero while proving
# the network works.
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

# The allowlist is opt-in and needs NET_ADMIN, so no plain session exercises it. This
# probe is the only test of the one active defence. Four constraints, each from a test
# that once failed for the wrong reason:
#
#   - /dev/tcp, not curl: neither curl nor wget is in the image, and a missing binary
#     makes the "blocked" test pass on 'command not found', a false positive.
#   - A literal IP, not a domain: CDN-fronted names resolve differently at firewall time
#     and probe time, so a domain-based test is intermittent.
#   - `timeout` on every probe: rules DROP rather than REJECT, so a blocked connect
#     hangs until TCP gives up.
#   - Mount the script, do not pass it as an argument: PowerShell rewrites quotes on the
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

# -CommandType Function is required: run from the repo directory, a bare
# `Get-Command agent` resolves to agent.ps1 itself as an ExternalScript and the check
# passes whether or not the profile was ever wired.
# A PreToolUse hook blocks on exit 2 and ONLY on exit 2; every other code is treated as an
# error and the tool call proceeds. CRLF line endings make the kernel look for an
# interpreter named `bash\r`, so the hook exits 127 and silently stops gating while still
# looking installed. That has happened here once already.
#
# A byte check rather than `bash -n`, which PASSES a CRLF script. Verified 2026-09-02.
# Checks the real hooks in your settings directory, not a synthetic one, so it catches the
# failure that actually occurs. Skipped when no settings directory is configured.
$settingsDir = $env:VESTIBULE_SETTINGS
if ($settingsDir -and (Test-Path -PathType Container (Join-Path $settingsDir 'claude\hooks'))) {
    $hooks = Get-ChildItem -Path (Join-Path $settingsDir 'claude\hooks') -Filter *.sh -File
    foreach ($h in $hooks) {
        Test-Item "hook has LF endings: $($h.Name)" {
            $bytes = [System.IO.File]::ReadAllBytes($h.FullName)
            -not ($bytes -contains 13)
        } "$($h.Name) contains CR bytes. The kernel will look for `bash\r`, the hook will exit 127 instead of 2, and a PreToolUse hook that does not exit 2 does not block."
    }
    if (-not $hooks) {
        Write-Host "  (no hook scripts in $settingsDir\claude\hooks)" -ForegroundColor DarkGray
    }
}

Test-Item "'agent' command is loaded" {
    [bool](Get-Command agent -CommandType Function -ErrorAction SilentlyContinue)
} "Run .\install.ps1, then open a new shell (or: . `$PROFILE)."

# Regression guard: `agent claude` once bound 'claude' to -Image, found no such image,
# rebuilt the whole thing under that tag and never ran the agent.
#
# Read the file, not the session. The ExternalScript resolution above reports the
# script's own binding rather than the function's, failing whenever verify runs without
# the profile loaded: by hand from the repo, or in CI, which is where a regression guard
# most has to work.
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

# Regression guard: the scope check once asked only whether the working directory held
# repositories as immediate children. A home directory with its repositories in ~\repos
# does not, so `agent` in C:\Users\you mounted .ssh, .aws and .claude read-write at /work
# while reporting a normal session.
#
# Dot-source the file rather than trust the session, for the reason above: the check has
# to test what is on disk. Get-AgentScopeRefusal takes its home directory as an argument,
# so these cases run against synthetic paths and cannot pass or fail on what happens to
# exist on the machine running them.
. (Join-Path $PSScriptRoot 'agent.ps1')
$tHome = 'C:\Users\tester'

foreach ($case in @(
    @{ Path = 'C:\';                        Refuse = $true  },
    @{ Path = 'C:\Users';                   Refuse = $true  },
    @{ Path = $tHome;                       Refuse = $true  },
    @{ Path = "$tHome\";                    Refuse = $true  },
    @{ Path = 'c:\users\TESTER';            Refuse = $true  },
    @{ Path = "$tHome\repos\..";            Refuse = $true  },
    @{ Path = "$tHome\Documents";           Refuse = $true  },
    @{ Path = "$tHome\OneDrive";            Refuse = $true  },
    @{ Path = "$tHome\OneDrive - Contoso";  Refuse = $true  },
    @{ Path = "$tHome\.ssh";                Refuse = $true  },
    @{ Path = "$tHome\.claude\projects";    Refuse = $true  },
    @{ Path = "$tHome\repos\project";       Refuse = $false },
    @{ Path = "$tHome\Documents\project";   Refuse = $false },
    @{ Path = 'D:\work\project';            Refuse = $false }
)) {
    $c    = $case
    $verb = if ($c.Refuse) { 'refuses' } else { 'allows' }
    Test-Item "scope $verb $($c.Path.Replace($tHome, '~'))" {
        $r = Get-AgentScopeRefusal -Path $c.Path -HomePath $tHome
        if ($c.Refuse) { $null -ne $r } else { $null -eq $r }
    } "Get-AgentScopeRefusal should have $verb this path."
}

Write-Host ""
if ($script:Failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Failures) check(s) failed." -ForegroundColor Red
exit 1
