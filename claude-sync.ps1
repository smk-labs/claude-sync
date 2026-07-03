# claude-sync: make local Claude Code sessions visible across all your
# Claude Desktop accounts on this PC.
#
# Claude Desktop keeps a separate Claude Code session index per account
# (one UUID folder per account under %APPDATA%\Claude\claude-code-sessions).
# Switch accounts and your session list looks empty, even though every
# transcript is still on disk in ~\.claude\projects.
#
# v2 sync: two passes over all index files. Per session, the copy with the
# newest lastActivityAt wins and is distributed everywhere (missing copies
# are created, stale copies are backed up then overwritten). If a session
# is archived in even one account, it is archived everywhere (un-archiving
# does not propagate). By default nothing is ever deleted, and deletions
# never propagate: a session deleted in one account comes back at the next
# sync. Pass -SyncDeletes to opt in to propagating deletions (see the
# ledger.tsv notes below); the auto-sync watcher never passes it.
# Every run that writes keeps a backup + manifest under
# ~\.claude\scripts\backups\<epoch>\; -Revert undoes the newest run,
# -DryRun shows what would happen without writing anything.
#
# Works on Windows PowerShell 5.1 and PowerShell 7+.
#
# https://github.com/SMKeramati/claude-sync

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Revert,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$AutoInstall,
    [switch]$AutoUninstall,
    [switch]$Watch,
    [switch]$Status,
    [switch]$SyncDeletes,
    [switch]$Version,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '2.1.0'

# $env:APPDATA fallback keeps the script parseable on non-Windows for testing.
$AppData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME 'AppData\Roaming' }

$SessionsDir = if ($env:CLAUDE_SYNC_SESSIONS_DIR) { $env:CLAUDE_SYNC_SESSIONS_DIR }
               else { Join-Path $AppData 'Claude\claude-code-sessions' }
$CanonicalDir = if ($env:CLAUDE_SYNC_HOME) { $env:CLAUDE_SYNC_HOME }
                else { Join-Path $HOME '.claude\scripts' }

$CanonicalPath = Join-Path $CanonicalDir 'claude-sync.ps1'
$LogPath       = Join-Path $CanonicalDir 'claude-sync.log'
$BackupsDir    = Join-Path $CanonicalDir 'backups'
$LedgerPath    = Join-Path $CanonicalDir 'ledger.tsv'
$LedgerAccountsPath = Join-Path $CanonicalDir '.ledger-accounts.tsv'
$RcBegin       = '# >>> claude-sync shortcut >>>'
$RcEnd         = '# <<< claude-sync shortcut <<<'
$TaskName      = 'claude-sync-watcher'
$KeepBackups   = 10

function Write-Log {
    param([string]$Message)
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

# Dry runs print to the console only; nothing on disk changes, log included.
function Out-Sync {
    param([string]$Message)
    if ($DryRun) { Write-Host $Message } else { Write-Log $Message }
}

function Get-AccountDirs {
    # One UUID folder per account. Skip non-account dirs like "_shared"
    # (left behind by other sync experiments/tools); they are not accounts.
    @(Get-ChildItem -Path $SessionsDir -Directory | Where-Object { $_.Name -notlike '_*' })
}

# ---------- core sync (v2) ------------------------------------------------
# Pass 1: inventory every <account>\<org>\local_*.json. The index JSON is
# compact and single-line; regex-extract the two fields we decide on.
function Get-Inventory {
    param($Accounts)
    $inv = New-Object System.Collections.Generic.List[object]
    foreach ($account in $Accounts) {
        foreach ($org in @(Get-ChildItem -Path $account.FullName -Directory -ErrorAction SilentlyContinue)) {
            foreach ($f in @(Get-ChildItem -Path $org.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue)) {
                $raw = [System.IO.File]::ReadAllText($f.FullName)
                $ts = [long]0
                if ($raw -match '"lastActivityAt":(\d+)') { $ts = [long]$Matches[1] }
                $arch = $false
                if ($raw -match '"isArchived":(true|false)') { $arch = ($Matches[1] -eq 'true') }
                $inv.Add([PSCustomObject]@{
                    Fname   = $f.Name
                    Ts      = $ts
                    Arch    = $arch
                    Path    = $f.FullName
                    Account = $account.Name
                })
            }
        }
    }
    return ,$inv
}

# Ledger: fname -> lastActivityAt recorded at the end of the last successful
# non-dry sync, for every session that was present in EVERY account at that
# time. Malformed rows (wrong column count, non-numeric ts) are skipped and
# never treated as a match. Missing/empty file is normal (first run).
function Get-Ledger {
    $ledger = @{}
    if (-not (Test-Path -LiteralPath $LedgerPath)) { return $ledger }
    foreach ($line in @(Get-Content -LiteralPath $LedgerPath -ErrorAction SilentlyContinue)) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -ne 2) { continue }
        $tsText = $parts[1]
        if ($tsText -notmatch '^\d+$') { continue }
        $ledger[$parts[0]] = [long]$tsText
    }
    return $ledger
}

# Companion file: the account names that counted as "everywhere" when the
# ledger was last written (one name per line). An account added AFTER that
# write must not make every ledgered session look "deleted somewhere", so
# -SyncDeletes judges absence only against this recorded set. Missing or
# empty file = fail safe: no deletion candidates at all. Lines containing
# a tab are malformed and skipped.
function Get-LedgerAccounts {
    $names = @{}
    if (-not (Test-Path -LiteralPath $LedgerAccountsPath)) { return $names }
    foreach ($line in @(Get-Content -LiteralPath $LedgerAccountsPath -ErrorAction SilentlyContinue)) {
        if (-not $line) { continue }
        if ($line.Contains("`t")) { continue }
        $names[$line] = $true
    }
    return $names
}

# Both files written atomically: temp file then Move-Item over the real path.
function Set-Ledger {
    param($Sessions, $Accounts)
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null

    $tmpPath = "$LedgerPath.tmp.$PID"
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($fname in ($Sessions.Keys | Sort-Object)) {
        $lines.Add("$fname`t$($Sessions[$fname].WinnerTs)")
    }
    if ($lines.Count -eq 0) {
        [System.IO.File]::WriteAllText($tmpPath, '')
    } else {
        [System.IO.File]::WriteAllText($tmpPath, (($lines -join "`n") + "`n"))
    }

    # Companion file: which accounts "present everywhere" meant this time.
    $tmpAcctPath = "$LedgerAccountsPath.tmp.$PID"
    $acctLines = New-Object System.Collections.Generic.List[string]
    foreach ($account in $Accounts) { $acctLines.Add($account.Name) }
    if ($acctLines.Count -eq 0) {
        [System.IO.File]::WriteAllText($tmpAcctPath, '')
    } else {
        [System.IO.File]::WriteAllText($tmpAcctPath, (($acctLines -join "`n") + "`n"))
    }

    Move-Item -LiteralPath $tmpPath -Destination $LedgerPath -Force
    Move-Item -LiteralPath $tmpAcctPath -Destination $LedgerAccountsPath -Force
}

function Invoke-Sync {
    if (-not (Test-Path $SessionsDir)) {
        Out-Sync "Sessions folder not found: $SessionsDir"
        Out-Sync 'Open Claude Desktop, go to Claude Code, and start one session first.'
        return 1
    }

    $accounts = @(Get-AccountDirs)
    if ($accounts.Count -lt 2) {
        Out-Sync 'Only one account folder found. Nothing to sync.'
        Out-Sync "Tip: log in to your other account in Claude Desktop, start one throwaway Claude Code session (a plain 'hi' is enough), quit Claude, then run claude-sync again."
        return 0
    }

    if ($DryRun) {
        Write-Host "DRY RUN: what a sync across $($accounts.Count) accounts would do. Nothing will be written."
    } else {
        Write-Log "Syncing sessions across $($accounts.Count) accounts..."
    }

    $inventory = Get-Inventory -Accounts $accounts

    # Pass 2: reduce per session. Winner = copy with max lastActivityAt
    # (ties: first seen). ArchOR = archived in at least one account.
    # PresentIn / MaxTs track per-account presence and the newest
    # lastActivityAt seen anywhere for that fname; -SyncDeletes uses both
    # to decide what qualifies for deletion.
    $sessions = @{}
    $invByPath = @{}
    foreach ($e in $inventory) {
        $invByPath[$e.Path] = $e
        if (-not $sessions.ContainsKey($e.Fname)) {
            $sessions[$e.Fname] = @{
                WinnerPath = $e.Path
                WinnerTs   = $e.Ts
                WinnerArch = $e.Arch
                ArchOR     = $e.Arch
                PresentIn  = @{ $e.Account = $true }
                MaxTs      = $e.Ts
            }
        } else {
            $s = $sessions[$e.Fname]
            if ($e.Ts -gt $s.WinnerTs) {
                $s.WinnerTs   = $e.Ts
                $s.WinnerPath = $e.Path
                $s.WinnerArch = $e.Arch
            }
            if ($e.Arch) { $s.ArchOR = $true }
            $s.PresentIn[$e.Account] = $true
            if ($e.Ts -gt $s.MaxTs) { $s.MaxTs = $e.Ts }
        }
    }

    # Backup run for this sync (shared by deletion and distribute below, so
    # both land under the same <epoch> run dir with one manifest).
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $backupRoot = Join-Path $BackupsDir "$epoch"
    $manifestPath = Join-Path $backupRoot 'manifest.tsv'
    $backupReady = $false

    # ---------- opt-in delete propagation (-SyncDeletes) ------------------
    # A session qualifies for deletion everywhere iff: it is in the ledger
    # (fully synced across all accounts once), it is now absent from at
    # least one account THAT WAS PART OF THE LAST LEDGER WRITE and still
    # exists, it is still present in at least one account, and no surviving
    # copy is newer than the ledger's recorded time (otherwise it was used
    # after the last full sync, so keep it: normal resurrection applies and
    # we log why). Absence is judged only against the recorded account set
    # from .ledger-accounts.tsv: an account added after that write knows
    # nothing about these sessions, and treating its emptiness as deletion
    # would wipe the entire history. The activity guard still looks at ALL
    # current copies, including ones in new accounts.
    $deletedSessions = @{}   # fname -> 1: deleted everywhere this run
    $acctDel = @{}           # account name -> hashtable of fnames deleted there
    foreach ($account in $accounts) { $acctDel[$account.Name] = @{} }

    if ($SyncDeletes) {
        $ledger = Get-Ledger
        $recordedAccounts = Get-LedgerAccounts
        # Recorded set intersected with accounts that still exist now.
        # Empty result (missing/empty companion file, or every recorded
        # account gone) = fail safe: no deletion candidates at all.
        $absenceAccounts = New-Object System.Collections.Generic.List[string]
        foreach ($account in $accounts) {
            if ($recordedAccounts.ContainsKey($account.Name)) { $absenceAccounts.Add($account.Name) }
        }
        foreach ($fname in @($sessions.Keys)) {
            if (-not $ledger.ContainsKey($fname)) { continue }
            $s = $sessions[$fname]
            if ($s.PresentIn.Count -eq 0) { continue }
            $absentSomewhere = $false
            foreach ($name in $absenceAccounts) {
                if (-not $s.PresentIn.ContainsKey($name)) { $absentSomewhere = $true; break }
            }
            if (-not $absentSomewhere) { continue }
            $ledgerTs = $ledger[$fname]
            if ($s.MaxTs -gt $ledgerTs) {
                Out-Sync "  keeping $fname: used after the last full sync (newer than ledger), so the deletion predates that activity"
                continue
            }

            # Qualifies: back up and remove every surviving copy.
            $survivingPaths = New-Object System.Collections.Generic.List[string]
            foreach ($e in $inventory) {
                if ($e.Fname -eq $fname) { $survivingPaths.Add($e.Path) }
            }
            if ($DryRun) {
                foreach ($p in $survivingPaths) { Write-Host "  would delete $p" }
            } else {
                if (-not $backupReady) {
                    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
                    $backupReady = $true
                }
                foreach ($p in $survivingPaths) {
                    $e = $invByPath[$p]
                    $orgName = Split-Path -Parent $p | Split-Path -Leaf
                    $backupPath = Join-Path (Join-Path (Join-Path $backupRoot $e.Account) $orgName) $fname
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
                    Copy-Item -LiteralPath $p -Destination $backupPath
                    Remove-Item -LiteralPath $p -Force
                    [System.IO.File]::AppendAllText($manifestPath, "deleted`t$p`t$backupPath`n")
                    $acctDel[$e.Account][$fname] = 1
                }
            }
            $deletedSessions[$fname] = 1
            # Exclude from the create/overwrite plan: this run must not
            # resurrect a session it just deleted.
            $sessions.Remove($fname)
        }
    }

    # Staging: sessions archived somewhere whose winner says
    # "isArchived":false get a flipped copy; that copy becomes canonical.
    # Its content differs from every non-archived copy, so those
    # destinations are updated even at equal timestamps.
    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-sync-staging-' + [guid]::NewGuid().ToString('N'))
    $stagedAny = $false
    foreach ($fname in @($sessions.Keys)) {
        $s = $sessions[$fname]
        $s.Canonical = $s.WinnerPath
        # In a dry run, decisions come from the inventory alone; skip the
        # staging writes so a dry run touches nothing at all.
        if ((-not $DryRun) -and $s.ArchOR -and -not $s.WinnerArch) {
            $raw = [System.IO.File]::ReadAllText($s.WinnerPath)
            if ($raw.Contains('"isArchived":false')) {
                if (-not $stagedAny) {
                    New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
                    $stagedAny = $true
                }
                $stagedPath = Join-Path $stagingDir $fname
                [System.IO.File]::WriteAllText($stagedPath, $raw.Replace('"isArchived":false', '"isArchived":true'))
                # Keep the winner's timestamp meaningful on the staged copy.
                (Get-Item -LiteralPath $stagedPath).LastWriteTime = (Get-Item -LiteralPath $s.WinnerPath).LastWriteTime
                $s.Canonical = $stagedPath
            }
        }
    }

    # Distribute. Copy-Item preserves LastWriteTime (the cp -p of Windows).
    # ($epoch / $backupRoot / $manifestPath / $backupReady are set above,
    # shared with the deletion pass so both land in the same run dir.)
    $createdSessions  = @{}   # fname -> 1: session appeared somewhere new
    $updatedSessions  = @{}   # fname -> 1: some copy moved to a newer state
    $archivedSessions = @{}   # fname -> 1: archive state propagated this run
    $acctNew = @{}            # account name -> hashtable of fnames created there
    $acctUpd = @{}            # account name -> hashtable of fnames updated there

    try {
        foreach ($account in $accounts) {
            $acctNew[$account.Name] = @{}
            $acctUpd[$account.Name] = @{}
            foreach ($org in @(Get-ChildItem -Path $account.FullName -Directory -ErrorAction SilentlyContinue)) {
                foreach ($fname in $sessions.Keys) {
                    $s = $sessions[$fname]
                    $dst = Join-Path $org.FullName $fname

                    if (-not $invByPath.ContainsKey($dst)) {
                        # Missing here: create it.
                        if ($DryRun) {
                            Write-Host "  would create $dst"
                        } else {
                            if (-not $backupReady) {
                                New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
                                $backupReady = $true
                            }
                            Copy-Item -LiteralPath $s.Canonical -Destination $dst
                            [System.IO.File]::AppendAllText($manifestPath, "created`t$dst`n")
                        }
                        $createdSessions[$fname] = 1
                        $acctNew[$account.Name][$fname] = 1
                        continue
                    }

                    # Never re-read files here; decide from the Pass-1 inventory.
                    $d = $invByPath[$dst]
                    $stale     = ($d.Ts -lt $s.WinnerTs)
                    $needsArch = ($s.ArchOR -and -not $d.Arch)
                    if (-not $stale -and -not $needsArch) { continue }

                    # Stale, or unarchived while the session is archived
                    # elsewhere: back up, then overwrite.
                    $backupPath = Join-Path (Join-Path (Join-Path $backupRoot $account.Name) $org.Name) $fname
                    if ($DryRun) {
                        Write-Host "  would overwrite $dst"
                    } else {
                        if (-not $backupReady) {
                            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
                            $backupReady = $true
                        }
                        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
                        Copy-Item -LiteralPath $dst -Destination $backupPath
                        Copy-Item -LiteralPath $s.Canonical -Destination $dst -Force
                        [System.IO.File]::AppendAllText($manifestPath, "overwrote`t$dst`t$backupPath`n")
                    }
                    if ($stale) {
                        $updatedSessions[$fname] = 1
                        $acctUpd[$account.Name][$fname] = 1
                    }
                    if ($needsArch) { $archivedSessions[$fname] = 1 }
                }
            }
        }
    }
    finally {
        if ($stagedAny) { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Per-account one-liners: unique sessions, never file-copy counts.
    foreach ($account in $accounts) {
        $n = $acctNew[$account.Name].Count
        $u = $acctUpd[$account.Name].Count
        $del = $acctDel[$account.Name].Count
        if (($n + $u + $del) -gt 0) {
            $line = '  account {0}: +{1} new session(s), {2} updated' -f $account.Name, $n, $u
            if ($del -gt 0) { $line += ', -{0} deleted' -f $del }
            Out-Sync $line
        }
    }

    $prefix = ''
    if ($DryRun) { $prefix = 'DRY RUN: would report: ' }
    $totalSessions = $sessions.Count + $deletedSessions.Count
    $summary = '{0}Done. {1} new session(s) appeared somewhere, {2} session(s) updated to a newer state, {3} session(s) archived everywhere (was archived in at least one account). {4} total session(s) across {5} account(s).' -f `
        $prefix, $createdSessions.Count, $updatedSessions.Count, $archivedSessions.Count, $totalSessions, $accounts.Count
    if ($SyncDeletes) {
        $summary += ', {0} session(s) deleted everywhere (deleted in at least one account)' -f $deletedSessions.Count
    }
    Out-Sync $summary

    # Update the ledger: every surviving session is now present in every
    # account (distribute converges them), so the post-run $sessions keys
    # are exactly what "present everywhere" means, and the current account
    # names are recorded alongside as what "everywhere" meant. Deleted
    # sessions are already excluded from $sessions. Skipped entirely on dry
    # runs and when fewer than 2 accounts exist (handled above).
    if (-not $DryRun) {
        Set-Ledger -Sessions $sessions -Accounts $accounts
    }

    # Prune old backup runs (keep the newest N).
    if (-not $DryRun -and (Test-Path $BackupsDir)) {
        $runs = @(Get-ChildItem -Path $BackupsDir -Directory |
                  Where-Object { $_.Name -match '^\d+(\.reverted)?$' } |
                  Sort-Object { [long](($_.Name -replace '\.reverted$', '')) } -Descending)
        if ($runs.Count -gt $KeepBackups) {
            foreach ($old in $runs[$KeepBackups..($runs.Count - 1)]) {
                Remove-Item -LiteralPath $old.FullName -Recurse -Force
            }
            Write-Log ('Pruned {0} old backup run(s); {1} kept.' -f ($runs.Count - $KeepBackups), $KeepBackups)
        }
    }
    return 0
}

# ---------- revert --------------------------------------------------------
function Invoke-Revert {
    $runs = @()
    if (Test-Path $BackupsDir) {
        $runs = @(Get-ChildItem -Path $BackupsDir -Directory |
                  Where-Object { $_.Name -match '^\d+$' } |
                  Sort-Object { [long]$_.Name } -Descending)
    }
    if ($runs.Count -eq 0) {
        Write-Host 'No backup runs found; nothing to revert.'
        return 1
    }
    $run = $runs[0]
    $manifestPath = Join-Path $run.FullName 'manifest.tsv'
    if (-not (Test-Path $manifestPath)) {
        Write-Host "Newest backup run $($run.Name) has no manifest.tsv; nothing to revert."
        return 1
    }

    Write-Log "Reverting sync run $($run.Name)..."
    $deleted = 0
    $restored = 0
    $undeleted = 0
    foreach ($line in @(Get-Content -LiteralPath $manifestPath)) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        if ($parts[0] -eq 'created') {
            if (Test-Path -LiteralPath $parts[1]) {
                Remove-Item -LiteralPath $parts[1] -Force
                $deleted++
                Write-Log "  deleted $($parts[1])"
            }
        } elseif ($parts[0] -eq 'overwrote') {
            Copy-Item -LiteralPath $parts[2] -Destination $parts[1] -Force
            $restored++
            Write-Log "  restored $($parts[1])"
        } elseif ($parts[0] -eq 'deleted') {
            # File does not exist at revert time (that is the point of a
            # deletion row); a plain copy-back from the backup is correct.
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $parts[1]) | Out-Null
            Copy-Item -LiteralPath $parts[2] -Destination $parts[1] -Force
            $undeleted++
            Write-Log "  restored (undeleted) $($parts[1])"
        }
    }
    Rename-Item -LiteralPath $run.FullName -NewName ($run.Name + '.reverted')
    Write-Log ('Revert complete: deleted {0} created file(s), restored {1} overwritten file(s), restored {2} deleted file(s). Backup kept as {3}.reverted.' -f $deleted, $restored, $undeleted, $run.Name)
    return 0
}

# ---------- watcher (hands-off mode) --------------------------------------
function Invoke-Watch {
    Write-Log '[watcher] Watcher started.'
    while ($true) {
        # Wait for the Claude Desktop main process to be running.
        while (-not (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)) {
            Start-Sleep -Seconds 5
        }
        $procId = @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)[0].Id
        Write-Log "[watcher] Claude detected (PID $procId). Waiting for quit..."
        while (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue) {
            Start-Sleep -Seconds 2
        }
        # Brief grace period for helpers to clean up.
        Start-Sleep -Seconds 3
        Write-Log '[watcher] Claude quit. Running sync...'
        Invoke-Sync | Out-Null
    }
}

function Install-AutoSync {
    if (-not (Test-Path $CanonicalPath)) {
        Write-Host "Run -Install first ($CanonicalPath not found)."
        return 1
    }
    $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Watch' -f $CanonicalPath
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host 'Auto-sync enabled. Sessions sync every time Claude Desktop quits.'
    Write-Host "Log: $LogPath"
    return 0
}

function Uninstall-AutoSync {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host 'Auto-sync task not installed. Nothing to do.'
        return 0
    }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host 'Auto-sync disabled.'
    return 0
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

    # If hands-off mode is on, restart the watcher so it runs the new script.
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Host 'Restarting auto-sync task with the updated script...'
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName
    }

    Write-Host 'Installed. Open a new terminal (or run ". $PROFILE"), then run: claude-sync'
}

function Uninstall-ClaudeSync {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Uninstall-AutoSync | Out-Null
    }
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
    Write-Host 'To delete the script, log, ledger and backups too:'
    Write-Host "  Remove-Item `"$CanonicalPath`", `"$LogPath`", `"$LedgerPath`", `"$LedgerAccountsPath`"; Remove-Item -Recurse `"$BackupsDir`""
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
        $n = @(Get-ChildItem -Path $shared -Recurse -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
        Write-Host ('  _shared (not an account folder, untouched): {0} file(s)' -f $n)
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
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    if ($task) {
        Write-Host 'Auto-sync: enabled (syncs when Claude Desktop quits)'
    } else {
        Write-Host 'Auto-sync: disabled'
    }
    $lastSync = $null
    if (Test-Path $LogPath) {
        $doneLines = @(Get-Content -Path $LogPath -ErrorAction SilentlyContinue | Where-Object { $_ -match '\] Done\.' })
        if ($doneLines.Count -gt 0 -and $doneLines[$doneLines.Count - 1] -match '^\[([^\]]+)\]') {
            $lastSync = $Matches[1]
        }
    }
    if ($lastSync) {
        Write-Host "Last sync: $lastSync"
    } else {
        Write-Host 'Last sync: never (no completed sync in the log)'
    }
    $runCount = 0
    if (Test-Path $BackupsDir) {
        $runCount = @(Get-ChildItem -Path $BackupsDir -Directory | Where-Object { $_.Name -match '^\d+$' }).Count
    }
    Write-Host "Backup runs stored: $runCount (use -Revert to undo the newest)"
}

function Show-Help {
    Write-Host @"
claude-sync v$ScriptVersion
Make local Claude Code sessions visible across all Claude Desktop accounts.
Newest copy of each session wins everywhere; archived in one account means
archived in all. By default nothing is ever deleted, and deletions never
propagate (a session deleted in one account comes back at the next sync).
Pass -SyncDeletes to opt in to propagating deletions everywhere instead.

Usage: claude-sync [option]

  (no option)     Run the sync.
  -DryRun         Show what a sync would do. Writes nothing.
  -SyncDeletes    Opt in to propagating deletions everywhere. Combine with
                  -DryRun to preview first. Never used by the auto-sync watcher.
  -Revert         Undo the most recent sync run from its backup (also
                  restores anything -SyncDeletes removed).
  -Status         Show accounts, session counts, install state, last sync,
                  stored backup runs.
  -Install        Copy this script to ~\.claude\scripts\ and register the
                  'claude-sync' command in your PowerShell profile. Re-run to update.
  -Uninstall      Remove the command from your PowerShell profile and the
                  auto-sync task (if enabled).
  -AutoInstall    Auto-sync every time Claude Desktop quits (Scheduled Task).
  -AutoUninstall  Disable auto-sync.
  -Version        Print version.
  -Help           This text.

Before the first sync: log in to the new account in Claude Desktop, start
one throwaway Claude Code session ('hi' is enough), quit Claude, then sync.
"@
}

# ---------- dispatcher ----------------------------------------------------
if     ($Help)          { Show-Help }
elseif ($Version)       { Write-Host "claude-sync v$ScriptVersion" }
elseif ($Install)       { Install-ClaudeSync }
elseif ($Uninstall)     { Uninstall-ClaudeSync }
elseif ($AutoInstall)   { exit (Install-AutoSync) }
elseif ($AutoUninstall) { exit (Uninstall-AutoSync) }
elseif ($Watch)         { Invoke-Watch }
elseif ($Status)        { Show-Status }
elseif ($Revert)        { exit (Invoke-Revert) }
else                    { exit (Invoke-Sync) }
