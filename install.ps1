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
$root = $PSScriptRoot

if (-not $SkipBuild) {
    Write-Host "Building $Image ..." -ForegroundColor Cyan
    $buildArgs = @('build', '-t', $Image)
    foreach ($a in $BuildArg) { $buildArgs += @('--build-arg', $a) }
    $buildArgs += (Join-Path $root 'image')
    docker @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "Image build failed." }
}

# CurrentUserAllHosts (profile.ps1), not $PROFILE. The default $PROFILE is
# host-specific, so `agent` would exist in Windows Terminal but not in VS Code's
# PowerShell console. This one runs for every host.
$profilePath = $PROFILE.CurrentUserAllHosts
$agentPath   = Join-Path $root 'agent.ps1'

# Guarded, so moving or deleting this repo does not throw on every shell start -
# an unguarded dot-source of a missing file errors in red, in every terminal,
# forever, until someone edits their profile. The warning keeps the diagnostic:
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

if (Select-String -Path $profilePath -SimpleMatch 'vestibule\agent.ps1' -Quiet) {
    Write-Host "Profile already wired." -ForegroundColor DarkGray
}
else {
    Add-Content $profilePath $block
    Write-Host "Added to $profilePath" -ForegroundColor Green
}

. (Join-Path $root 'agent.ps1')

Write-Host ""
Write-Host "Done. In a new shell:" -ForegroundColor Green
Write-Host "    cd <any project>" -ForegroundColor DarkGray
Write-Host "    agent" -ForegroundColor DarkGray
Write-Host ""
Write-Host "First run only - log in inside the container:" -ForegroundColor DarkGray
Write-Host "    claude   then /login" -ForegroundColor DarkGray
