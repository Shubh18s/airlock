<#
  Contained agent sessions.

  Dot-source from your $PROFILE; install.ps1 does this for you.

  Commands:
      agent                    run a contained session in the current directory
      Get-AgentSessions        read the host-side session record
      New-AgentDevcontainer    add .devcontainer/ to a project, for Ctrl+Shift+P

  Scope comes from the working directory, so there is nothing to configure per
  project. The mount list is the security policy; see README.md.
#>

# Captured at dot-source time so the functions can find image/ and template/
# regardless of what directory they are later called from.
$Global:VestibuleRoot = $PSScriptRoot


# Machine-local state, stored outside this repository.
#
# The record is only evidence if a session cannot edit it. Held inside the repository,
# that depended on the working directory: running `agent` from the repository itself
# mounts it read-write and places the log at /work/sessions/sessions.jsonl.
$Global:VestibuleLog = Join-Path $env:LOCALAPPDATA 'vestibule\sessions.jsonl'


function Invoke-Docker {
    <#
      Run docker with $ErrorActionPreference forced to Continue.

      Docker writes ordinary progress to stderr. Under 'Stop', PowerShell turns redirected
      native stderr into a terminating error, so `agent` fails as soon as a caller pipes
      or redirects its output, as a script or CI job does. Exit codes are checked
      explicitly at every call site, so nothing is lost by not throwing here.
    #>
    [CmdletBinding(PositionalBinding = $false)]
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker @Arguments } finally { $ErrorActionPreference = $prev }
}


function Write-AgentSessionRecord {
    <#
      Append one session record to the host-side log.

      Shared by both launchers so the path and shape are defined once. `agent` calls it
      after a session ends and can report an outcome; the devcontainer path calls it from
      initializeCommand, which runs on the host before the container starts, so it records
      the start and leaves outcome fields null. There is no host-side hook for a
      devcontainer ending.
    #>
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [hashtable] $Fields,
        [string]    $MountedPath   # warn if the log would sit inside it
    )

    $dir = Split-Path -Parent $Global:VestibuleLog
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Assert the invariant rather than assume it. If a mount ever contains the log, the
    # record is no longer independent of the session it describes.
    if ($MountedPath -and $Global:VestibuleLog.StartsWith($MountedPath, 'OrdinalIgnoreCase')) {
        Write-Warning "Session log is inside the mounted path. This session can edit its own record."
    }

    Add-Content -Path $Global:VestibuleLog `
                -Value (([pscustomobject]$Fields) | ConvertTo-Json -Compress) -Encoding utf8
}


function Get-GitWorkingState {
    <#
      Map of path -> two-letter git status code for a working tree.

      Sampled before and after a session so the record can report what that session
      changed. `git status --short` read only afterwards answers a different question,
      "what is dirty now", which counts files that were already modified before the
      container started and attributes them to it.
    #>
    [CmdletBinding(PositionalBinding = $false)]
    param([string] $Path)

    $state = @{}
    if (-not $Path -or -not (Test-Path (Join-Path $Path '.git'))) { return $state }

    foreach ($line in @(git -C $Path status --short 2>$null)) {
        # Format is XY<space>PATH. A rename reads "old -> new" and is kept as one entry.
        if ($line.Length -gt 3) { $state[$line.Substring(3)] = $line.Substring(0, 2) }
    }
    $state
}


function agent {
    # PositionalBinding = $false is required. With positional binding enabled,
    # `agent claude` binds 'claude' to -Image, finds no such image, and rebuilds under
    # that tag instead of running the agent. Disabled, unmatched arguments fall through
    # to $Command.
    [CmdletBinding(PositionalBinding = $false)]
    param(
        # Mount a scratch volume at /work in place of the current directory, and
        # nothing else from this machine. See the mount list below.
        [switch] $Isolated,
        [switch] $NoNetwork,  # no egress at all; a cloud agent cannot reach its API
        [switch] $Build,
        [switch] $Force,       # override the contains-repositories guard below
        [switch] $SkipVerify,  # skip the post-build check; see the build step below

        # Apply the egress allowlist. Without it the available postures are unrestricted
        # egress or none at all, and none at all prevents a hosted agent from reaching
        # its API.
        #
        # Costs four capabilities, and only during startup: NET_ADMIN and NET_RAW for
        # iptables, SETUID and SETGID for the handover to `dev`. no-new-privileges is
        # retained, so the session cannot climb back afterwards. Running the script
        # under sudo instead would mean dropping no-new-privileges for the whole
        # session, leaving a permanent escalation path.
        #
        # The intended replacement is a forward proxy the container has no route
        # around, which requires no capabilities. See BACKLOG.md, item 8.
        [switch] $Firewall,

        # docker --build-arg. Mainly HARNESSES, which agent CLIs the image contains:
        #   agent -Build -BuildArg "HARNESSES=@anthropic-ai/claude-code opencode-ai"
        [string[]] $BuildArg,

        # Session environment, NAME=VALUE. Session-scoped by design: env dies with the
        # container, unlike anything written into the home volume.
        #
        # A credential passed here is readable by the agent for the life of the session.
        # Use short-lived, narrowly scoped values; never a general-purpose key.
        #   $c = aws configure export-credentials --profile bedrock-agent | ConvertFrom-Json
        #   agent -Env "AWS_ACCESS_KEY_ID=$($c.AccessKeyId)",
        #              "AWS_SESSION_TOKEN=$($c.SessionToken)" opencode
        [string[]] $Env,

        [int]    $MemoryGb   = 8,
        [int]    $Cpus       = 4,
        [string] $Image      = 'vestibule:1',
        [string] $ContextDir = (Join-Path $Global:VestibuleRoot 'image'),

        # Command to run instead of bash, flags included: `agent claude --resume`
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Command
    )

    $ErrorActionPreference = 'Stop'

    # Reject a mistyped flag rather than treat it as a command. With positional binding
    # disabled, an unrecognised argument falls through to $Command and is used as the
    # executable, so `agent -NoNetworl` starts a container under the default posture and
    # fails afterwards inside docker. A flag that selects a security posture must not
    # fail by silently applying a different one.
    #
    # First position only: an executable name never begins with '-', while flags intended
    # for the harness legitimately do, as in `agent claude --resume`.
    if ($Command -and $Command[0].StartsWith('-')) {
        $switches = $MyInvocation.MyCommand.Parameters.GetEnumerator() |
                    Where-Object { $_.Key -ne 'Command' -and
                                   $_.Key -notin [System.Management.Automation.PSCmdlet]::CommonParameters } |
                    ForEach-Object { "-$($_.Key)" }
        throw ("Unknown flag '$($Command[0])'. Nothing was started.`n" +
               "Flags for agent: $($switches -join ' ')`n" +
               "Flags for the harness go after it: agent claude --resume")
    }

    if ($Firewall -and $NoNetwork) {
        throw "-Firewall and -NoNetwork are contradictory. Pick one."
    }

    foreach ($e in $Env) {
        if ($e -notmatch '^[A-Za-z_][A-Za-z0-9_]*=') {
            throw "-Env entries must be NAME=VALUE. Got: $e"
        }
    }

    # Docker volume names allow [a-zA-Z0-9_.-] only; fold anything else.
    $project = (Split-Path -Leaf $PWD.Path) -replace '[^a-zA-Z0-9_.-]', '-'
    $homeVol = "agent-home-$project"

    # Refuse a directory that contains repositories rather than being one: running from
    # ~/repos would mount every project it holds. Isolated sessions are exempt.
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
                       "cd into one repository, or -Isolated for a scratch volume, or -Force to override.")
            }
        }
    }

    if ($Build -or $BuildArg -or -not (docker images -q $Image)) {
        Write-Host "Building $Image ..." -ForegroundColor Cyan
        $buildArgs = @('build', '-t', $Image)
        foreach ($a in $BuildArg) { $buildArgs += @('--build-arg', $a) }
        $buildArgs += $ContextDir
        Invoke-Docker @buildArgs
        if ($LASTEXITCODE -ne 0) { throw "Image build failed; not starting a container." }

        # The posture is assembled from strings, so nothing validates it before it is
        # sent. verify.ps1 inspects the resulting container instead, which is what
        # separates a documented control from one that silently does nothing. Run after
        # a build, where the subject of the checks has changed, rather than before every
        # session. Roughly 19 seconds.
        if (-not $SkipVerify) {
            & (Join-Path $Global:VestibuleRoot 'verify.ps1') -Image $Image
            if ($LASTEXITCODE -ne 0) {
                throw "Image built but failed verification. Fix it, or re-run with -SkipVerify."
            }
        }
    }

    # docker refuses -t when stdin is not a terminal, so scripts and CI need -i alone.
    # Its error names the symptom rather than the cause, which makes it hard to place.
    $tty = if ([Console]::IsInputRedirected) { '-i' } else { '-it' }

    # No mounts in this array. Every -v is assembled in a single block below, so the
    # mount list can be read in one place. Mounts declared here applied to every posture,
    # including ones they were never reviewed against: -Isolated previously received a
    # home volume, a shared cache and a host bind by this route.
    $dockerArgs = @(
        'run', $tty, '--rm',
        '--name', "agent-$project",
        '--cap-drop=ALL',
        '--security-opt=no-new-privileges',
        "--memory=${MemoryGb}g", "--memory-swap=${MemoryGb}g",
        "--cpus=$Cpus",
        '--pids-limit=512'
    )

    if ($Firewall) {
        # Start as root so the script can write iptables rules without sudo, which
        # no-new-privileges would refuse. setpriv hands the session to `dev` before
        # anything else runs; see the command assembly below.
        $dockerArgs += @('--user', 'root',
                         '--cap-add=NET_ADMIN', '--cap-add=NET_RAW',
                         '--cap-add=SETUID',    '--cap-add=SETGID')
        $dockerArgs += @('-e', 'AGENT_ALLOWLIST=/work/.vestibule/allowed-domains.txt')
        # setpriv changes the uid but not the environment. Without this, HOME stays
        # /root from the startup step and tools look for config where `dev` cannot
        # read, surfacing as a permission error on a path nobody configured.
        # init-firewall.sh ignores all three, so setting them early is harmless.
        $dockerArgs += @('-e', 'HOME=/home/dev', '-e', 'USER=dev', '-e', 'LOGNAME=dev')
    }

    # Session environment; validated at the top. Names are echoed so the session's inputs
    # are visible; values are not, since the common case is a credential.
    foreach ($e in $Env) { $dockerArgs += @('-e', $e) }

    # Per-project network. On Docker's default bridge every container can reach every
    # other by IP; there is no name resolution, but an address is enough to scan a
    # sibling, which defeats per-project isolation. A user-defined network removes that
    # path and leaves outbound access unchanged. Reaching a service elsewhere is then a
    # deliberate act:  docker network connect agent-net-<project> ollama
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

    # ---- the mount list ---------------------------------------------------------
    # -Isolated mounts nothing from this machine: no project directory, and equally no
    # login, transcripts or preferences. The consequence is a login per isolated session,
    # in exchange for the container holding no credential to exfiltrate.
    $dockerArgs += @('-w', '/work')

    if ($Isolated) {
        $dockerArgs += @('-v', "agent-scratch-${project}:/work")
        Write-Host "ISOLATED  scratch volume only, nothing from this machine" -ForegroundColor Green
    }
    else {
        # $PWD.Path, never the literal string: `-v "pwd:/work"` is read as a volume
        # name, silently creating an empty volume called `pwd` and mounting that.
        $dockerArgs += @('-v', "$($PWD.Path):/work")
        # Login and transcripts. Per project, so sessions cannot read each other's.
        $dockerArgs += @('-v', "${homeVol}:/home/dev")
        # Shared wheel cache, holding public artifacts only. It crosses project
        # boundaries, which is why isolated sessions do not receive it.
        $dockerArgs += @('-v', 'uv-cache:/home/dev/.cache/uv')

        # The global CLAUDE.md only: preferences, not secrets. Never the whole
        # ~/.claude, which holds the host credential and every past project's
        # transcripts. $HOME rather than USERPROFILE is portable. Test-Path is
        # required because Docker silently creates an empty directory when a bind
        # source does not exist.
        $globalMd = Join-Path $HOME '.claude\CLAUDE.md'
        if (Test-Path -PathType Leaf $globalMd) {
            $dockerArgs += @('-v', "${globalMd}:/home/dev/.claude/CLAUDE.md:ro")
        }

        Write-Host "MOUNTED   your project directory is live and writable" -ForegroundColor Yellow
    }

    # The mount list is the security policy, so report all of it, derived from the
    # arguments being passed. A readout restated by each branch drifts from the command
    # it describes: the -Isolated line previously reported that nothing was mounted while
    # a bind declared elsewhere still applied.
    #
    # A spec is source:dest[:mode]. Splitting on ':' is wrong on Windows, where the
    # source carries a drive letter, so anchor the destination as an absolute Unix path.
    $mounts = for ($i = 0; $i -lt $dockerArgs.Count - 1; $i++) {
        if ($dockerArgs[$i] -ne '-v') { continue }
        if ($dockerArgs[$i + 1] -match '^(?<src>.+?):(?<dst>/[^:]+)(?::(?<mode>[a-z,]+))?$') {
            [pscustomobject]@{
                Dest   = $Matches['dst']
                Source = $Matches['src']
                Mode   = if ($Matches['mode']) { $Matches['mode'] } else { 'rw' }
                # A bind reaches the host filesystem; a volume is stored inside the
                # Linux VM. Distinguished because only the first crosses the boundary.
                Kind   = if ($Matches['src'] -match '^[A-Za-z]:|[\\/]') { 'bind' } else { 'vol' }
            }
        }
    }

    $width = ($mounts | ForEach-Object { $_.Dest.Length } | Measure-Object -Maximum).Maximum
    $label = 'mounts  '
    foreach ($m in $mounts) {
        $suffix = if ($m.Mode -ne 'rw') { " ($($m.Mode))" } else { '' }
        $colour = if ($m.Kind -eq 'bind') { 'Yellow' } else { 'DarkGray' }
        Write-Host ("{0}  {1}  {2}  {3}{4}" -f $label, $m.Dest.PadRight($width), $m.Kind.PadRight(4), $m.Source, $suffix) `
                   -ForegroundColor $colour
        $label = '        '
    }
    if ($NoNetwork)    { Write-Host "network   none" -ForegroundColor DarkGray }
    else               { Write-Host "network   $net" -ForegroundColor DarkGray }
    if ($Firewall) {
        Write-Host "egress    allowlist (NET_ADMIN granted back)" -ForegroundColor Yellow

        # init-firewall.sh skips a missing allowlist file silently and applies only its
        # five built-in domains. github.com is not among them, and because the rules DROP
        # rather than REJECT, git hangs with no indication of the cause. Warn here, where
        # the host can still determine whether the file exists.
        if ($Isolated) {
            Write-Warning ("Isolated: your project's .vestibule/allowed-domains.txt is not mounted. " +
                           "Only the built-in domains apply unless the scratch volume holds its own " +
                           "at /work/.vestibule/allowed-domains.txt.")
        }
        elseif (-not (Test-Path -PathType Leaf (Join-Path $PWD.Path '.vestibule\allowed-domains.txt'))) {
            Write-Warning ("No .vestibule\allowed-domains.txt here, so only the 5 built-in domains " +
                           "apply. github.com is not one of them and git will hang. Start one with:`n" +
                           "  copy `"$(Join-Path $Global:VestibuleRoot 'template\allowed-domains.txt')`" .vestibule\")
        }
    }
    if ($Env) {
        $names = ($Env | ForEach-Object { ($_ -split '=', 2)[0] }) -join ', '
        Write-Host "env       $names (readable by the session)" -ForegroundColor Yellow
    }

    $dockerArgs += $Image

    if ($Firewall) {
        # Rules must exist before anything else runs, and iptables does not survive a
        # restart, so this belongs here rather than in the image. setpriv then drops to
        # `dev` and execs the real command: root exists only for the setup step, and
        # --inh-caps=-all leaves the session none of the four capabilities.
        $inner = if ($Command) { $Command -join ' ' } else { 'bash' }
        $drop  = 'setpriv --reuid=dev --regid=dev --clear-groups --inh-caps=-all'
        $dockerArgs += @('bash', '-c', "/usr/local/bin/init-firewall.sh && exec $drop $inner")
    }
    elseif ($Command) { $dockerArgs += $Command }
    else              { $dockerArgs += 'bash' }

    # ---- session record -------------------------------------------------------
    # Written on the host: anything logged from inside a container is only as
    # trustworthy as that container. No session mounts this path, so the record survives
    # a compromised one intact.
    #
    # It captures configuration and outcome, not behaviour. Recording what the agent ran
    # would require process auditing, which requires capabilities this design drops.
    $imageId = (docker images -q --no-trunc $Image | Select-Object -First 1)
    $started = Get-Date
    $mountedPath = if ($Isolated) { $null } else { $PWD.Path }

    $gitBefore = $null
    if ($mountedPath -and (Test-Path (Join-Path $mountedPath '.git'))) {
        $gitBefore = (git -C $mountedPath rev-parse HEAD 2>$null)
    }
    $stateBefore = Get-GitWorkingState -Path $mountedPath

    Invoke-Docker @dockerArgs
    $exit = $LASTEXITCODE

    # Docker exits 125 when the daemon declined to create the container: a name collision
    # with a session already running, an unusable flag, a missing image. Nothing ran, so
    # there is no outcome to describe. The row is still written, since a failed launch is
    # worth recording, but fields that would otherwise describe a session that never
    # existed are left null rather than zero: unknown, not clean.
    $launched = ($exit -ne 125)

    # ---- what this session changed in the working tree -------------------------
    # The mount is live, so edits are already on disk when the session ends and git on
    # the host can see them. Git cannot distinguish them from work that was already
    # uncommitted, so compare the two samples rather than reporting the later one alone.
    # A file counts if its status changed: newly dirty, newly clean, or dirty in a
    # different way.
    $changed  = @()
    $gitAfter = $null
    if ($launched) {
        if ($mountedPath -and (Test-Path (Join-Path $mountedPath '.git'))) {
            $gitAfter = (git -C $mountedPath rev-parse HEAD 2>$null)
        }
        $stateAfter = Get-GitWorkingState -Path $mountedPath

        $paths = @($stateBefore.Keys) + @($stateAfter.Keys) | Sort-Object -Unique
        foreach ($p in $paths) {
            if ($stateBefore[$p] -eq $stateAfter[$p]) { continue }
            # '--' marks a path that was dirty before and is clean now, which a status
            # listing cannot express because the file no longer appears in it.
            $code = if ($stateAfter.ContainsKey($p)) { $stateAfter[$p] } else { '--' }
            $changed += "$code $p"
        }
    }

    Write-AgentSessionRecord -MountedPath $mountedPath -Fields @{
        started    = $started.ToString('o')
        launcher   = 'agent'
        seconds    = [int]((Get-Date) - $started).TotalSeconds
        project    = $project
        mounted    = $mountedPath
        image      = $imageId
        network    = if ($NoNetwork) { 'none' } else { $net }
        firewall   = [bool]$Firewall
        # Where-Object first: piping an empty $Env into ForEach-Object still iterates
        # once in PowerShell 5.1, which recorded [""] rather than [].
        envNames   = @($Env | Where-Object { $_ } | ForEach-Object { ($_ -split '=', 2)[0] })
        command    = if ($Command) { $Command -join ' ' } else { 'bash' }
        exitCode   = $exit
        headBefore = $gitBefore
        headAfter  = $gitAfter
        dirtyFiles = if ($launched) { $changed.Count } else { $null }
    }

    if (-not $launched) {
        Write-Host ""
        Write-Host "container did not start, so nothing about this session was recorded" -ForegroundColor DarkGray
    }
    elseif ($changed.Count -gt 0) {
        Write-Host ""
        Write-Host "$($changed.Count) file(s) changed by this session in $mountedPath" -ForegroundColor Yellow
        $changed | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        if ($changed.Count -gt 10) { Write-Host "  ... and $($changed.Count - 10) more" -ForegroundColor DarkGray }
        # Both are null in a repo with no commits yet, so guard before substringing.
        if ($gitBefore -and $gitAfter -and $gitBefore -ne $gitAfter) {
            Write-Host "  HEAD moved: $($gitBefore.Substring(0,7)) -> $($gitAfter.Substring(0,7))" -ForegroundColor DarkGray
        }
    }
    elseif ($mountedPath) {
        Write-Host ""
        Write-Host "no working-tree changes from this session in $mountedPath" -ForegroundColor DarkGray
    }
}


function Get-AgentSessions {
    <#
      Read the host-side session record written by `agent`.

          Get-AgentSessions              last 20, this machine
          Get-AgentSessions -Project x   one project
          Get-AgentSessions -Last 100

      Shows how each session was configured and how it ended. It does not show what the
      agent did inside; that would require process auditing, which requires capabilities
      this design drops deliberately.
    #>
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [string] $Project,
        [int]    $Last = 20
    )

    if (-not (Test-Path $Global:VestibuleLog)) {
        Write-Host "No sessions recorded yet." -ForegroundColor DarkGray
        return
    }

    $rows = Get-Content $Global:VestibuleLog | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
    if ($Project) { $rows = $rows | Where-Object { $_.project -eq $Project } }

    $rows | Select-Object -Last $Last | ForEach-Object {
        [pscustomobject]@{
            When     = ([datetime]$_.started).ToString('MM-dd HH:mm')
            Project  = $_.project
            Via      = $_.launcher
            Cmd      = $_.command
            Secs     = $_.seconds
            Net      = if ($_.firewall) { 'allowlist' } else { $_.network }
            Env      = if ($_.envNames) { $_.envNames -join ',' } else { '' }
            Changed  = $_.dirtyFiles
            Exit     = $_.exitCode
        }
    } | Format-Table -AutoSize
}


function New-AgentDevcontainer {
    <#
      Write .devcontainer/ into a project so VS Code's "Reopen in Container" works.
      Required only for the editor path; `agent` works without it.
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

    # __PROJECT__ becomes the folder name, so the home volume matches the one `agent`
    # derives and both launchers share a single login and history. __VESTIBULE__ becomes
    # this repository's path, which initializeCommand requires to locate the recorder.
    # JSON has no variables, so both are substituted at generation time.
    (Get-Content (Join-Path $template 'devcontainer.json') -Raw) `
        -replace '__PROJECT__', $project `
        -replace '__VESTIBULE__', $Global:VestibuleRoot.Replace('\', '\\') |
        Set-Content (Join-Path $target 'devcontainer.json') -Encoding utf8

    # The allowlist is not a devcontainer file: that path cannot apply the firewall at
    # all, and `agent -Firewall` reads it whether or not a devcontainer exists. It is
    # seeded here only because this is the one function that writes into a project.
    $vest = Join-Path $Path '.vestibule'
    New-Item -ItemType Directory -Force -Path $vest | Out-Null
    Copy-Item (Join-Path $template 'allowed-domains.txt') $vest -Force

    Write-Host "Wrote $target for project '$project'." -ForegroundColor Green
    Write-Host "Wrote $vest\allowed-domains.txt for 'agent -Firewall'." -ForegroundColor Green
    Write-Host "VS Code: Ctrl+Shift+P -> Dev Containers: Reopen in Container" -ForegroundColor DarkGray
}
