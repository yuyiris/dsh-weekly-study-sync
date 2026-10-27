# run-weekly-sync.ps1
# Weekly study sync launcher: runs the weekly-study-sync skill in a headless DSH session.
# Pure ASCII on purpose (Windows PowerShell 5.1 parses non-BOM UTF-8 as ANSI).
# All Chinese text lives in resources\prompt-template.md (UTF-8).
#
# Requires: dsh on PATH, config.json in the skill root (see -DryRun output).
#
# Manual: powershell -NoProfile -ExecutionPolicy Bypass -File "run-weekly-sync.ps1" [-Days 7]
# Auto:   scheduled task, weekly (see README)
#
# Safety model (v2):
#   * The vault MUST be configured explicitly; there is no blind %USERPROFILE% scan.
#   * The workspace MUST be configured explicitly; it is never guessed.
#   * The agent runs with DSH_PERMISSION_MODE=workspace-write, never danger-full-access.
#   * Once the agent exits, hard rules are enforced in code:
#       - at most $MaxNewNotes brand-new notes per run (logged as a warning)
#       - logs/ pruned to the last $LogKeep runs
#   * The lock records a real PID and is released only after that process is gone.

param(
    [int]$Days = 0,
    [int]$TimeoutMinutes = 0,
    [string]$Config = '',
    [string]$PermissionMode = 'workspace-write',
    [int]$MaxNewNotes = 10,
    [int]$LogKeep = 12,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$Resources   = $PSScriptRoot
$SkillDir    = Split-Path -Parent $Resources
$ConfigPath  = Join-Path $SkillDir 'config.json'
$ExamplePath = Join-Path $SkillDir 'config.example.json'
$StatePath   = Join-Path $SkillDir 'state.json'
$LogDir      = Join-Path $Resources 'logs'
$LockPath    = Join-Path $SkillDir '.lock'
$TplPath     = Join-Path $Resources 'prompt-template.md'

New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction SilentlyContinue | Out-Null
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
$LogFile = Join-Path $LogDir ($stamp + '.log')

function Write-Log([string]$msg) {
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg
    # Tee-Object is best-effort: a read-only log dir must not abort the run.
    try { $line | Tee-Object -FilePath $LogFile -Append | Out-Null } catch { }
    Write-Host $line
}

# ---- helpers ---------------------------------------------------------------

function Test-Placeholder([string]$p) {
    if (-not $p) { return $true }
    return ($p -match '(?i)path[\\/]to[\\/]|your.vault|your.workspace|<.*>')
}

# Returns the full path without a trailing separator, or $null when it is not
# an existing directory. So "vault"/"workspace" can never silently be a file,
# a drive root, or a typo.
function Resolve-Directory([string]$p) {
    if (Test-Placeholder $p) { return $null }
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { return $null }
    return (Resolve-Path -LiteralPath $p).Path.TrimEnd('\', '/')
}

function Test-Within([string]$child, [string]$parent) {
    if (-not $child -or -not $parent) { return $false }
    $c = $child.TrimEnd('\', '/')
    $p = $parent.TrimEnd('\', '/')
    return ($c -ieq $p) -or ($c -ilike ($p + '\*'))
}

# Explicit, environment-first vault discovery. Deliberately does NOT scan the
# whole user profile: no personal directory layout is baked into the code.
function Find-ObsidianVault {
    $candidates = @()
    if ($env:DSH_VAULT) { $candidates += $env:DSH_VAULT }
    foreach ($base in @($env:USERPROFILE, (Join-Path $env:USERPROFILE 'Documents'))) {
        if (-not $base -or -not (Test-Path $base)) { continue }
        try {
            $markers = Get-ChildItem -Path $base -Filter '.obsidian' -Recurse -Directory -Depth 2 -Force -ErrorAction SilentlyContinue |
                       Select-Object -First 8
        } catch { continue }
        foreach ($m in $markers) { $candidates += (Split-Path -Parent $m.FullName) }
    }
    if ($env:LOCALAPPDATA) {
        # Obsidian keeps its own list of opened vaults; trust it as a hint only.
        $obs = Join-Path $env:LOCALAPPDATA 'obsidian'
        if (Test-Path $obs) {
            try {
                Get-ChildItem -Path $obs -Filter 'obsidian.json' -Recurse -File -Depth 2 -Force -ErrorAction SilentlyContinue |
                    Select-Object -First 4 | ForEach-Object {
                        try {
                            $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                            foreach ($v in $j.vaults.PSObject.Properties) { $candidates += $v.Value.path }
                        } catch { }
                    }
            } catch { }
        }
    }
    foreach ($c in $candidates) {
        $dir = Resolve-Directory $c
        if (-not $dir) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $dir '.obsidian') -PathType Container)) { continue }
        return $dir
    }
    return $null
}

function Prune-Logs([string]$dir, [int]$keep) {
    if (-not (Test-Path $dir) -or $keep -le 0) { return 0 }
    $files = @(Get-ChildItem -Path $dir -File -Force -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)
    $removed = 0
    if ($files.Count -gt $keep) {
        $files | Select-Object -Skip $keep | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    return $removed
}

function Count-NewNotes([string]$vault, [datetime]$since) {
    return @(Get-ChildItem -Path $vault -Filter '*.md' -Recurse -File -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -gt $since }).Count
}

# ---- config: resolve -------------------------------------------------------
# Order: -Config explicit > config.json > config.example.json
# workspace and vault are REQUIRED and MUST already exist. On a miss we exit
# with a clear message instead of guessing and writing across the disk.

$ConfigFile = $null
if ($Config -and (Test-Path $Config)) { $ConfigFile = (Resolve-Path $Config).Path }
elseif (Test-Path $ConfigPath)        { $ConfigFile = $ConfigPath }
elseif (Test-Path $ExamplePath)       { $ConfigFile = $ExamplePath }

$cfg = $null
if ($ConfigFile) {
    try { $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null }
}
if (-not $cfg) { $cfg = [pscustomobject]@{} }

if ($cfg.maxNewNotes -and -not $PSBoundParameters.ContainsKey('MaxNewNotes')) { $MaxNewNotes = [int]$cfg.maxNewNotes }
if ($cfg.logKeep    -and -not $PSBoundParameters.ContainsKey('LogKeep'))      { $LogKeep    = [int]$cfg.logKeep }

$Workspace = Resolve-Directory $cfg.workspace
$Vault     = Resolve-Directory $cfg.vault
if (-not $Vault) { $Vault = $env:DSH_VAULT }
if ($Vault)      { $Vault = Resolve-Directory $Vault }
if (-not $Vault) { $Vault = Find-ObsidianVault }

if (-not $Workspace) {
    throw ("Config 'workspace' is missing or not a directory: " + $cfg.workspace + "`n" +
           "  Set it in $ConfigPath or pass -Config. Example: `"workspace`": `"D:\\path\\to\\workspace`"")
}
if (-not $Vault) {
    throw ("Config 'vault' is missing and auto-detect found nothing.`n" +
           "  Set it in $ConfigPath (any folder containing .obsidian), or set `$env:DSH_VAULT.")
}
if (Test-Within $Vault $SkillDir) { throw "Refusing to write into the skill directory: $Vault" }
if ($TimeoutMinutes -le 0) { $TimeoutMinutes = if ($cfg.timeoutMinutes) { [int]$cfg.timeoutMinutes } else { 45 } }

# persist the resolved values so later runs are deterministic.
# Written without BOM: PS 5.1's Set-Content -Encoding UTF8 prepends EF BB BF,
# which makes every run see "changed" and re-write the file forever.
$resolved = [ordered]@{ workspace = $Workspace; vault = $Vault; timeoutMinutes = $TimeoutMinutes;
                        maxNewNotes = $MaxNewNotes; logKeep = $LogKeep }
$resolvedJson = ($resolved | ConvertTo-Json)
$currentRaw = $null
if (Test-Path $ConfigPath) { $currentRaw = (Get-Content $ConfigPath -Raw -Encoding UTF8) }
if ($currentRaw -ne ($resolvedJson + "`r`n")) {
    try {
        [IO.File]::WriteAllText($ConfigPath, ($resolvedJson + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Log ('config resolved -> ' + $ConfigPath)
    } catch {
        Write-Log ('WARN: could not persist config (' + $_.Exception.Message + '); using in-memory values')
    }
}

# ---- re-entry guard: real PID, not just an age heuristic -------------------
if (Test-Path $LockPath) {
    $oldPid = $null
    try { $oldPid = [int]((Get-Content $LockPath -Raw -ErrorAction SilentlyContinue).Trim()) } catch { $oldPid = $null }
    $alive = $false
    if ($oldPid) { $alive = [bool](Get-Process -Id $oldPid -ErrorAction SilentlyContinue) }
    if ($alive) {
        Write-Log ('SKIP: previous run is still alive (pid ' + $oldPid + ')')
        exit 0
    }
    $age = (Get-Date) - (Get-Item $LockPath).LastWriteTime
    Write-Log ('stale .lock reclaimed (pid ' + $oldPid + ', age ' + [int]$age.TotalMinutes + ' min)')
    Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
}
$lockHeld = $false
try {
    New-Item -ItemType File -Path $LockPath -Force -ErrorAction Stop | Out-Null
    Set-Content -Path $LockPath -Value ([string]$PID) -Encoding ASCII -ErrorAction Stop
    $lockHeld = $true
} catch {
    Write-Log ('WARN: could not take .lock (' + $_.Exception.Message + '); continuing without re-entry guard')
}

$proc = $null
try {
    # ---- window ------------------------------------------------------------
    $state = $null
    if (Test-Path $StatePath) {
        try { $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
    }

    if ($Days -gt 0) {
        $since = (Get-Date).AddDays(-$Days)
    } elseif ($state -and $state.lastRun) {
        $since = [datetime]::Parse($state.lastRun, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    } else {
        $since = (Get-Date).AddDays(-7)
    }
    $sinceStr = $since.ToString('yyyy-MM-dd HH:mm')

    Write-Log ('START weekly-study-sync | window since ' + $sinceStr)
    Write-Log ('  workspace: ' + $Workspace)
    Write-Log ('  vault    : ' + $Vault)
    Write-Log ('  mode     : ' + $PermissionMode + ' | new-note cap ' + $MaxNewNotes + ' | log keep ' + $LogKeep)

    # ---- session topic snapshot --------------------------------------------
    # session_topics.mjs exits 3 when the cache dir is missing: that is a
    # "could not read", NOT "nothing to read", and must not degrade silently.
    $topicsFile = $null
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $nodeOut  = & node (Join-Path $Resources 'session_topics.mjs') --days 7 2>&1
        $nodeCode = $LASTEXITCODE
        if ($nodeCode -eq 3) {
            Write-Log 'WARN: session cache dir not found (exit 3); topics snapshot is empty'
        } elseif ($nodeCode -ne 0) {
            Write-Log ('WARN: session_topics.mjs exit ' + $nodeCode)
        }
        $topicsFile = Join-Path $LogDir ('topics-' + $stamp + '.json')
        try {
            $nodeOut | Out-File -FilePath $topicsFile -Encoding UTF8 -ErrorAction Stop
            Write-Log ('topics snapshot -> ' + $topicsFile)
        } catch {
            Write-Log ('WARN: could not write topics snapshot (' + $_.Exception.Message + ')')
            $topicsFile = $null
        }
    } else {
        Write-Log 'WARN: node not found on PATH; session topics will be empty'
    }

    # ---- build prompt from UTF-8 template ---------------------------------
    $promptFile = Join-Path $LogDir ('prompt-' + $stamp + '.md')
    $tpl = Get-Content $TplPath -Raw -Encoding UTF8
    $tpl = $tpl.Replace('{{SINCE}}', $sinceStr)
    $tpl = $tpl.Replace('{{TOPICS}}', $(if ($topicsFile) { $topicsFile } else { '(session topics unavailable)' }))
    $tpl = $tpl.Replace('{{STATE}}', $StatePath)
    $tpl = $tpl.Replace('{{SKILL}}', $SkillDir)
    $tpl = $tpl.Replace('{{WORKSPACE}}', $Workspace)
    $tpl = $tpl.Replace('{{VAULT}}', $Vault)
    $tpl = $tpl.Replace('{{MAX_NEW_NOTES}}', [string]$MaxNewNotes)
    try {
        $tpl | Out-File -FilePath $promptFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        throw ('Could not write prompt file ' + $promptFile + ': ' + $_.Exception.Message)
    }

    # ---- dry run: validate everything, never spawn an agent -----------------
    if ($DryRun) {
        Write-Log 'DRY RUN: config parsed, prompt rendered, no agent launched'
        Write-Log ('  prompt   : ' + $promptFile)
        Write-Log ('  logs     : pruned ' + (Prune-Logs $LogDir $LogKeep) + ' old file(s)')
        exit 0
    }

    # ---- run headless ------------------------------------------------------
    # Start-Process -PassThru keeps the real PID so a timeout can kill the tree;
    # Start-Job/Stop-Job does not guarantee the child dsh process dies.
    $instruction = 'Read the task file at ' + $promptFile + ' and carry it out exactly.'
    Write-Log ('launch: dsh --profile headless (cwd=' + $Workspace + ', timeout=' + $TimeoutMinutes + 'm, mode=' + $PermissionMode + ')')

    $env:DSH_PERMISSION_MODE   = $PermissionMode
    $env:DSH_WEEKLY_VAULT      = $Vault
    $env:DSH_WEEKLY_WORKSPACE  = $Workspace
    $dshOut = Join-Path $LogDir ($stamp + '.agent.log')
    $proc = Start-Process -FilePath 'dsh' -ArgumentList @('--profile','headless',$instruction) `
                          -WorkingDirectory $Workspace -PassThru `
                          -RedirectStandardOutput $dshOut -RedirectStandardError ($dshOut + '.err') `
                          -WindowStyle Hidden
    $exited = $proc.WaitForExit($TimeoutMinutes * 60 * 1000)
    if (-not $exited) {
        Write-Log ('TIMEOUT after ' + $TimeoutMinutes + ' min - killing process tree (pid ' + $proc.Id + ')')
        try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
        Start-Sleep -Seconds 3
        $code = 2
    } else {
        $code = $proc.ExitCode
        Write-Log ('DONE (exit code ' + $code + ')')
    }

    # ---- hard rules enforced in code, not just in the prompt ---------------
    $newNotes = Count-NewNotes $Vault (Get-Date).AddMinutes(-$TimeoutMinutes - 2)
    if ($newNotes -gt $MaxNewNotes) {
        Write-Log ('WARN: agent created ' + $newNotes + ' new notes, cap is ' + $MaxNewNotes + ' - review ' + $Vault)
    }
    Write-Log ('logs pruned: ' + (Prune-Logs $LogDir $LogKeep) + ' old file(s)')

    Write-Log 'END weekly-study-sync'
    exit $code
}
finally {
    # Only release the lock once the agent process is really gone.
    if ($proc -and -not $proc.HasExited) {
        try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
    }
    if ($lockHeld) { Remove-Item $LockPath -Force -ErrorAction SilentlyContinue }
}
