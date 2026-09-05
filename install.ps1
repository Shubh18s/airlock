<#
  One-time setup. Builds the image and makes `agent` available in every shell.

      .\install.ps1

  Re-run safely; it will not duplicate the $PROFILE line.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string] $Image = 'vestibule:1',
    [switch] $SkipBuild,

    # Passed to `docker build` as --build-arg. Mainly HARNESSES, which decides which
    # agent CLIs the image contains:
    #   .\install.ps1 -BuildArg "HARNESSES=@anthropic-ai/claude-code opencode-ai"
    [string[]] $BuildArg
)

$ErrorActionPreference = 'Stop'
$root      = $PSScriptRoot
$agentPath = Join-Path $root 'agent.ps1'

# Load the launcher first, for two reasons. It defines Invoke-Docker, which the build
# below needs. And verify.ps1 checks that `agent` resolves as a function: loaded only at
# the end, that check saw nothing and every first install failed on a control that was
# working.
#
# verify.ps1 is called with &, so it reads this function through the scope chain and
# needs no load of its own. Verified live 2026-09-05: a host reinstall passed the
# "'agent' command is loaded" check. Note what this does NOT do: the function lands in
# this script's scope, not the calling shell's, which is why the closing message still
# asks for a new one.
. $agentPath


# --- profile ---

# CurrentUserAllHosts (profile.ps1), not $PROFILE. The default $PROFILE is
# host-specific, so `agent` would exist in Windows Terminal but not in VS Code's
# PowerShell console. This one runs for every host.
$profilePath = $PROFILE.CurrentUserAllHosts

# Guarded, so moving or deleting this repo does not throw on every shell start:
# an unguarded dot-source of a missing file errors in red, in every terminal,
# forever, until someone edits their profile. The warning keeps the diagnostic;
# silence would leave you wondering why `agent` stopped existing.
$block = @"

# Contained agent sessions
`$vestibule = "$agentPath"
if (Test-Path `$vestibule) { . `$vestibule } else { Write-Warning "vestibule not found at `$vestibule" }
"@

if (-not (Test-Path $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
    Write-Host "Created $profilePath" -ForegroundColor DarkGray
}

# Read the path out of the profile rather than looking for the folder name. Matching a
# literal 'vestibule\agent.ps1' assumed the clone was named vestibule, so a checkout in
# vestibule-main, the name a downloaded zip unpacks to, never matched and every re-run
# appended another copy of the block.
$wired     = Select-String -Path $profilePath -Pattern '^\s*\$vestibule\s*=\s*"(.+)"' | Select-Object -First 1
$wiredPath = if ($wired) { $wired.Matches[0].Groups[1].Value } else { $null }

if (-not $wiredPath) {
    Add-Content $profilePath $block
    Write-Host "Added to $profilePath" -ForegroundColor Green
}
elseif ($wiredPath -eq $agentPath) {
    Write-Host "Profile already wired." -ForegroundColor DarkGray
}
else {
    # Appending would leave two blocks, the stale one warning on every shell start.
    # Rewriting someone's profile unasked is worse, so say what to change and stop.
    Write-Warning ("$profilePath already points at another copy:`n" +
                   "    $wiredPath`n" +
                   "Edit that line to this one, or remove it and re-run:`n" +
                   "    $agentPath")
}


# --- image ---

if (-not $SkipBuild) {
    Write-Host "Building $Image ..." -ForegroundColor Cyan
    $buildArgs = @('build', '-t', $Image)
    foreach ($a in $BuildArg) { $buildArgs += @('--build-arg', $a) }
    $buildArgs += (Join-Path $root 'image')

    # Invoke-Docker, not docker: docker writes ordinary progress to stderr, and under
    # 'Stop' PowerShell turns redirected native stderr into a terminating error, so a
    # piped or logged install failed partway through a build that was fine.
    Invoke-Docker @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "Image build failed." }
}

# Verify the image rather than trusting that it built. Nothing validates the security
# posture on the way out, so this check is what stands between a claim in the README and
# a control that silently does nothing. Runs here and after `agent -Build`, which is
# where the thing it checks changes.
& (Join-Path $root 'verify.ps1') -Image $Image
if ($LASTEXITCODE -ne 0) { throw "Verification failed. The image is not usable as configured." }


Write-Host ""
Write-Host "Done. In a new shell:" -ForegroundColor Green
Write-Host "    cd <any project>" -ForegroundColor DarkGray
Write-Host "    agent" -ForegroundColor DarkGray
Write-Host ""
Write-Host "First run only, log in inside the container:" -ForegroundColor DarkGray
Write-Host "    claude   then /login" -ForegroundColor DarkGray
