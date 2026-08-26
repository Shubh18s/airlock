<#
  Contained agent sessions.

  Dot-source from your $PROFILE (install.ps1 does this for you):
      . <path-to-repo>\agent.ps1

  Defines two commands:
      agent                    run a contained session in the current directory
      New-AgentDevcontainer    add .devcontainer/ to a project, for Ctrl+Shift+P

  Scope comes from the working directory, so there is nothing to configure per
  project. The mount list is the security policy - see README.md.
#>

# Captured at dot-source time so the functions can find image/ and template/
# regardless of what directory they are later called from.
$Global:VestibuleRoot = $PSScriptRoot


function agent {
    # PositionalBinding = $false is load-bearing: without it `agent claude` binds
    # 'claude' to -Image, finds no such image, and rebuilds under that tag instead of
    # running the agent. Off, unmatched args fall through to $Command.
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [switch] $Isolated,   # mount nothing from this machine
        [switch] $NoNetwork,  # no egress; breaks installs, fine for a local model
        [switch] $Build,
        [switch] $Force,      # override the contains-repositories guard below

        # docker --build-arg. Mainly HARNESSES, which agent CLIs the image contains:
        #   agent -Build -BuildArg "HARNESSES=@anthropic-ai/claude-code opencode-ai"
        [string[]] $BuildArg,

        [int]    $MemoryGb   = 8,
        [int]    $Cpus       = 4,
        [string] $Image      = 'vestibule:1',
        [string] $ContextDir = (Join-Path $Global:VestibuleRoot 'image'),

        # Command to run instead of bash, flags included: `agent claude --resume`
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Command
    )

    $ErrorActionPreference = 'Stop'

    # Docker volume names allow [a-zA-Z0-9_.-] only; fold anything else.
    $project = (Split-Path -Leaf $PWD.Path) -replace '[^a-zA-Z0-9_.-]', '-'
    $homeVol = "agent-home-$project"

    # Refuse a directory that CONTAINS repositories rather than being one: running from
    # ~/repos would hand the agent every project you own. Isolated sessions are exempt.
    # Test-Path on .git catches a normal repo (directory) and a worktree (file) alike.
    if (-not $Isolated -and -not $Force) {
        if (-not (Test-Path (Join-Path $PWD.Path '.git'))) {
            $inner = @(Get-ChildItem -Directory -Force -ErrorAction SilentlyContinue |
                       Where-Object { Test-Path (Join-Path $_.FullName '.git') })
            if ($inner.Count -gt 0) {
                $names = ($inner | Select-Object -First 3 -ExpandProperty Name) -join ', '
                if ($inner.Count -gt 3) { $names += ', ...' }
                throw ("$($PWD.Path) is not a repository, but contains $($inner.Count): $names`n" +
                       "Mounting it would give the agent every project inside.`n" +
                       "cd into one repository, or -Isolated to mount nothing, or -Force to override.")
            }
        }
    }

    if ($Build -or $BuildArg -or -not (docker images -q $Image)) {
        Write-Host "Building $Image ..." -ForegroundColor Cyan
        $buildArgs = @('build', '-t', $Image)
        foreach ($a in $BuildArg) { $buildArgs += @('--build-arg', $a) }
        $buildArgs += $ContextDir
        docker @buildArgs
        if ($LASTEXITCODE -ne 0) { throw "Image build failed; not starting a container." }
    }

    $dockerArgs = @(
        'run', '-it', '--rm',
        '--name', "agent-$project",
        # Login and transcripts. Per project, so sessions cannot read each other's.
        '-v', "${homeVol}:/home/dev",
        # Shared wheel cache. Public artifacts only - a deliberate exception.
        '-v', 'uv-cache:/home/dev/.cache/uv',
        '--cap-drop=ALL',
        '--security-opt=no-new-privileges',
        "--memory=${MemoryGb}g", "--memory-swap=${MemoryGb}g",
        "--cpus=$Cpus",
        '--pids-limit=512'
    )

    # Global CLAUDE.md only -- preferences, not secrets. Never the whole ~/.claude, which
    # holds the host credential and every past project's transcripts.
    # $HOME, not USERPROFILE: portable. Test-Path is required -- Docker silently creates
    # an empty DIRECTORY at the source path when the file does not exist.
    $globalMd = Join-Path $HOME '.claude\CLAUDE.md'
    if (Test-Path -PathType Leaf $globalMd) {
        $dockerArgs += @('-v', "${globalMd}:/home/dev/.claude/CLAUDE.md:ro")
    }

    # Per-project network. On Docker's DEFAULT bridge every container can reach every
    # other by IP -- no name resolution, but an address is enough to scan a sibling,
    # which defeats per-project isolation. A user-defined network removes that path and
    # leaves outbound access unchanged. To reach a service elsewhere (a local model),
    # attach it deliberately:  docker network connect agent-net-<project> ollama
    if ($NoNetwork) {
        $dockerArgs += '--network=none'
    }
    else {
        $net = "agent-net-$project"
        # --filter name= is a substring match, so anchor it or `foo` matches `foo-bar`.
        if (-not (docker network ls --filter "name=^${net}$" --format '{{.Name}}')) {
            docker network create $net | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not create network $net." }
        }
        $dockerArgs += @('--network', $net)
    }

    if ($Isolated) {
        $dockerArgs += @('-v', "agent-scratch-${project}:/work", '-w', '/work')
        Write-Host "ISOLATED  nothing from this machine is mounted" -ForegroundColor Green
    }
    else {
        # $PWD.Path, never the literal string - `-v "pwd:/work"` silently creates an
        # empty volume named `pwd` and mounts that instead.
        $dockerArgs += @('-v', "$($PWD.Path):/work", '-w', '/work')
        Write-Host "MOUNTED   $($PWD.Path)" -ForegroundColor Yellow
    }

    Write-Host "home vol  $homeVol" -ForegroundColor DarkGray
    if (-not $NoNetwork) { Write-Host "network   $net" -ForegroundColor DarkGray }

    $dockerArgs += $Image
    if ($Command) { $dockerArgs += $Command } else { $dockerArgs += 'bash' }

    docker @dockerArgs
}


function New-AgentDevcontainer {
    <#
      Drop .devcontainer/ into a project so VS Code's "Reopen in Container" works.
      Only needed for the editor path; `agent` works without it.
    #>
    [CmdletBinding()]
    param(
        [string] $Path = $PWD.Path,
        [switch] $Force
    )

    $ErrorActionPreference = 'Stop'

    $project  = (Split-Path -Leaf (Resolve-Path $Path)) -replace '[^a-zA-Z0-9_.-]', '-'
    $target   = Join-Path $Path '.devcontainer'
    $template = Join-Path $Global:VestibuleRoot 'template'

    if ((Test-Path $target) -and -not $Force) {
        throw "$target already exists. Re-run with -Force to overwrite."
    }

    New-Item -ItemType Directory -Force -Path $target | Out-Null

    # __PROJECT__ becomes the folder name, so the home volume matches what `agent`
    # would pick. Both launchers then share one login and one session history.
    (Get-Content (Join-Path $template 'devcontainer.json') -Raw) `
        -replace '__PROJECT__', $project |
        Set-Content (Join-Path $target 'devcontainer.json') -Encoding utf8

    Copy-Item (Join-Path $template 'allowed-domains.txt') $target -Force

    Write-Host "Wrote $target for project '$project'." -ForegroundColor Green
    Write-Host "VS Code: Ctrl+Shift+P -> Dev Containers: Reopen in Container" -ForegroundColor DarkGray
}
