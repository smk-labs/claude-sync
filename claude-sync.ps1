# claude-sync: make local Claude Code sessions visible across all your
# Claude Desktop accounts on this PC.
#
# Claude Desktop keeps a separate Claude Code session index per account
# (one UUID folder per account under %APPDATA%\Claude\claude-code-sessions).
# Switch accounts and your session list looks empty, even though every
# transcript is still on disk in ~\.claude\projects.
# This script copies the missing index files across accounts.
# Additive only: it never overwrites and never deletes.
#
# Works on Windows PowerShell 5.1 and PowerShell 7+.
#
# https://github.com/SMKeramati/claude-sync

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Version,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

# $env:APPDATA fallback keeps the script parseable on non-Windows for testing.
$AppData       = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME 'AppData\Roaming' }
$SessionsDir   = Join-Path $AppData 'Claude\claude-code-sessions'
$CanonicalDir  = Join-Path $HOME '.claude\scripts'
$CanonicalPath = Join-Path $CanonicalDir 'claude-sync.ps1'
$LogPath       = Join-Path $CanonicalDir 'claude-sync.log'
$RcBegin       = '# >>> claude-sync shortcut >>>'
$RcEnd         = '# <<< claude-sync shortcut <<<'

function Write-Log {
    param([string]$Message)
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Get-AccountDirs {
    # One UUID folder per account. Newer Claude builds also keep a "_shared"
    # cross-account store there; it is not an account, leave it alone.
    @(Get-ChildItem -Path $SessionsDir -Directory | Where-Object { $_.Name -notlike '_*' })
}

# ---------- core sync ----------------------------------------------------
function Invoke-Sync {
    if (-not (Test-Path $SessionsDir)) {
        Write-Log "Sessions folder not found: $SessionsDir"
        Write-Log 'Open Claude Desktop, go to Claude Code, and start one session first.'
        exit 1
    }

    $accounts = Get-AccountDirs
    if ($accounts.Count -lt 2) {
        Write-Log 'Only one account folder found. Nothing to sync.'
        Write-Log "Tip: log in to your other account in Claude Desktop, start one throwaway Claude Code session (a plain 'hi' is enough), quit Claude, then run claude-sync again."
        return
    }

    Write-Log "Syncing sessions across $($accounts.Count) accounts..."
    $total = 0

    foreach ($srcAccount in $accounts) {
        foreach ($srcOrg in @(Get-ChildItem -Path $srcAccount.FullName -Directory)) {
            foreach ($dstAccount in $accounts) {
                if ($dstAccount.FullName -eq $srcAccount.FullName) { continue }

                foreach ($dstOrg in @(Get-ChildItem -Path $dstAccount.FullName -Directory)) {
                    $count = 0
                    foreach ($f in @(Get-ChildItem -Path $srcOrg.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue)) {
                        $dst = Join-Path $dstOrg.FullName $f.Name
                        if (-not (Test-Path $dst)) {
                            Copy-Item -Path $f.FullName -Destination $dst
                            $count++
                            $total++
                        }
                    }
                    if ($count -gt 0) {
                        Write-Log ('  +{0} session(s): {1} -> {2}' -f $count, $srcAccount.Name, $dstAccount.Name)
                    }
                }
            }
        }
    }

    Write-Log "Done. $total new session(s) synced."
}

# ---------- install / uninstall ------------------------------------------
function Install-ClaudeSync {
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    if ($PSCommandPath -ne $CanonicalPath) {
        Write-Host "Installing script -> $CanonicalPath"
        Copy-Item -Path $PSCommandPath -Destination $CanonicalPath -Force
    } else {
        Write-Host 'Running from canonical location; script already in place.'
    }
    Unblock-File -Path $CanonicalPath -ErrorAction SilentlyContinue

    $profilePath = $PROFILE
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Force -Path $profilePath | Out-Null
    }
    $content = Get-Content -Path $profilePath -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains($RcBegin)) {
        Write-Host "Command already registered in $profilePath; leaving it alone."
        Write-Host "(Script at $CanonicalPath was refreshed.)"
    } else {
        Write-Host "Registering 'claude-sync' command in $profilePath"
        $block = @"

$RcBegin
function claude-sync { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "`$HOME\.claude\scripts\claude-sync.ps1" @args }
$RcEnd
"@
        Add-Content -Path $profilePath -Value $block
    }
    Write-Host 'Installed. Open a new terminal (or run ". $PROFILE"), then run: claude-sync'
}

function Uninstall-ClaudeSync {
    $profilePath = $PROFILE
    $content = if (Test-Path $profilePath) { Get-Content -Path $profilePath -Raw } else { $null }
    if (-not $content -or -not $content.Contains($RcBegin)) {
        Write-Host "No claude-sync block found in $profilePath. Nothing to remove."
        return
    }
    Write-Host "Removing 'claude-sync' command from $profilePath"
    Copy-Item -Path $profilePath -Destination ("{0}.bak.{1}" -f $profilePath, (Get-Date -Format 'yyyyMMddHHmmss'))
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in @(Get-Content -Path $profilePath)) {
        if ($line -eq $RcBegin) { $skip = $true; continue }
        if ($line -eq $RcEnd)   { $skip = $false; continue }
        if (-not $skip) { $out.Add($line) }
    }
    Set-Content -Path $profilePath -Value $out
    Write-Host 'Removed. Open a new terminal for it to take effect.'
    Write-Host "To delete the script and log too:"
    Write-Host "  Remove-Item `"$CanonicalPath`", `"$LogPath`""
}

# ---------- status / help -------------------------------------------------
function Show-Status {
    Write-Host "claude-sync v$ScriptVersion"
    Write-Host "Sessions dir: $SessionsDir"
    if (-not (Test-Path $SessionsDir)) {
        Write-Host '  (not found: open Claude Code in Claude Desktop once)'
        return
    }
    foreach ($a in Get-AccountDirs) {
        $n = @(Get-ChildItem -Path $a.FullName -Recurse -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
        Write-Host ('  account {0}: {1} session index file(s)' -f $a.Name, $n)
    }
    $shared = Join-Path $SessionsDir '_shared'
    if (Test-Path $shared) {
        $n = @(Get-ChildItem -Path $shared -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
        Write-Host ("  _shared (Claude's own cross-account store, untouched): {0} file(s)" -f $n)
    }
    if (Test-Path $CanonicalPath) {
        Write-Host "Script: installed at $CanonicalPath"
    } else {
        Write-Host 'Script: not installed (run -Install)'
    }
    $content = if (Test-Path $PROFILE) { Get-Content -Path $PROFILE -Raw -ErrorAction SilentlyContinue } else { $null }
    if ($content -and $content.Contains($RcBegin)) {
        Write-Host "Command: registered in $PROFILE"
    } else {
        Write-Host 'Command: not registered'
    }
}

function Show-Help {
    Write-Host @"
claude-sync v$ScriptVersion
Make local Claude Code sessions visible across all Claude Desktop accounts.

Usage: claude-sync [option]

  (no option)   Run the sync.
  -Status       Show detected accounts, session counts, install state.
  -Install      Copy this script to ~\.claude\scripts\ and register the
                'claude-sync' command in your PowerShell profile. Re-run to update.
  -Uninstall    Remove the command from your PowerShell profile.
  -Version      Print version.
  -Help         This text.

Before the first sync: log in to the new account in Claude Desktop, start
one throwaway Claude Code session ('hi' is enough), quit Claude, then sync.
"@
}

# ---------- dispatcher ----------------------------------------------------
if     ($Help)      { Show-Help }
elseif ($Version)   { Write-Host "claude-sync v$ScriptVersion" }
elseif ($Install)   { Install-ClaudeSync }
elseif ($Uninstall) { Uninstall-ClaudeSync }
elseif ($Status)    { Show-Status }
else                { Invoke-Sync }
