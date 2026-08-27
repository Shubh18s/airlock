<#
  Record a devcontainer session, from the host.

  Called by initializeCommand in a project's .devcontainer/devcontainer.json, which
  VS Code runs on the host before the container is created. That makes it the only
  hook where the record is out of the session's reach, matching how `agent` writes.

  There is no host-side hook for a devcontainer ending, so outcome fields stay null:
  this records that a session started and how it was configured, not how it went.

      .\record-session.ps1 -Project myproject -Mounted C:\repos\myproject
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)] [string] $Project,
    [Parameter(Mandatory)] [string] $Mounted,
    [string] $Image = 'vestibule:1'
)

$ErrorActionPreference = 'Stop'

# Defines Write-AgentSessionRecord and $Global:VestibuleRoot. Dot-sourcing is safe:
# agent.ps1 only declares functions, so nothing runs as a side effect.
. (Join-Path $PSScriptRoot 'agent.ps1')

$head = $null
if (Test-Path (Join-Path $Mounted '.git')) {
    $head = (git -C $Mounted rev-parse HEAD 2>$null)
}

Write-AgentSessionRecord -MountedPath $Mounted -Fields @{
    started    = (Get-Date).ToString('o')
    launcher   = 'devcontainer'
    seconds    = $null
    project    = $Project
    mounted    = $Mounted
    image      = (docker images -q --no-trunc $Image | Select-Object -First 1)
    network    = 'default'      # VS Code manages the network; agent's per-project one does not apply
    firewall   = $false         # enabled per project in devcontainer.json, not visible here
    envNames   = @()
    command    = 'devcontainer'
    exitCode   = $null
    headBefore = $head
    headAfter  = $null
    dirtyFiles = $null
}
