# claude-sync: make local Claude Code sessions visible across all your
# Claude Desktop accounts on this PC.
#
# Claude Desktop keeps a separate Claude Code session index per account
# (one UUID folder per account under %APPDATA%\Claude\claude-code-sessions).
# Switch accounts and your session list looks empty, even though every
# transcript is still on disk in ~\.claude\projects.
# This script reconciles the index files across accounts:
#   - the copy with the newest lastActivityAt wins,
#   - archived-in-one means archived-everywhere,
#   - every overwrite is backed up first and can be undone with -Revert,
#   - deletions propagate by default: a session fully synced once,
#     then deleted in ANY account and untouched since, is deleted everywhere
#     (backed up first, revertible). -NoDeletes turns that off for a run;
#     because a skipped deletion is re-copied from the surviving accounts,
#     -NoDeletes doubles as the restore path for an accidental delete.
#     See the ledger machinery below.
#
# It also syncs customization across PROFILES: multi-profile launchers
# (claude-deck) give each profile its own data dir under
# %APPDATA%\Claude Profiles\<name>\, so local MCP servers (the mcpServers
# block of claude_desktop_config.json) and installed Desktop Extensions
# diverge per profile. Every sync reconciles mcpServers across all data
# dirs: missing servers are added everywhere, and when two profiles define
# the SAME server differently, the definition from the config file with the
# newest mtime wins and overwrites the others (edit a server in any
# profile, it propagates). Removing a server from any profile removes it
# everywhere too, tracked by an MCP ledger so "deleted" is never confused
# with "never had it"; -NoDeletes skips (and thereby restores) removals.
# The app's own settings (the "preferences" block: bypass-permissions,
# scheduled tasks, sidebar mode, ...) are reconciled the same way, but
# ADD-ONLY: a key present anywhere is propagated everywhere, nothing is
# ever removed, and on a conflict the newest-mtime config wins, so the
# last change you made is the one that spreads. The per-account maps
# (*ByAccount) merge entry by entry, so turning a setting on for one
# account never drops another account's entry. A profile that has never
# been opened has no preferences of its own and therefore can never blank
# a setting for the rest -- the failure mode the MCP ledger guards against.
# Every other key of each config file is untouched. Extensions stay
# copy-only (additive). Config writes are backed up into the run's
# manifest, so -Revert undoes them too. (No claude-deck profiles on this
# machine yet? The whole layer is dormant and costs nothing.)
# Logins and cookies are deliberately never synced: separate accounts are
# the whole point of profiles. Per-profile window/workspace state (the
# launchPreview* lists) is left alone for the same reason. Claude Code
# customization (plugins, skills, hooks, memory in ~\.claude) is already
# machine-global and needs no syncing.
#
# Deliberately NOT synced either: %APPDATA%\Claude\local-agent-mode-sessions
# (a parallel index tree that appeared in mid-2026 builds). It is empty so
# far and its semantics are unknown; syncing it blindly could corrupt agent
# state. Revisit once Claude ships whatever it is for.
#
# Feature parity with claude-sync.sh v3.0.0 (the macOS script). JSON
# handling uses PowerShell's built-in ConvertFrom-Json/ConvertTo-Json:
# no dependencies. Works on Windows PowerShell 5.1 and PowerShell 7+.
#
# https://github.com/SMKeramati/claude-sync

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoDeletes,
    [switch]$Revert,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$AutoInstall,
    [switch]$AutoUninstall,
    [switch]$Watch,
    [switch]$Status,
    [switch]$Version,
    [switch]$Help,
    # GNU-style spellings (--dry-run, --status, ...) land here as loose
    # strings and are mapped onto the switches above, so muscle memory from
    # the macOS script keeps working. Anything unrecognized prints usage.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '3.0.0'

# $env:APPDATA fallback keeps the script parseable on non-Windows for testing.
$AppData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME 'AppData\Roaming' }

# CLAUDE_SYNC_* overrides exist so tests can point the script at a
# throwaway tree instead of the real one (same names as the macOS script).
$SessionsDir = if ($env:CLAUDE_SYNC_SESSIONS_DIR) { $env:CLAUDE_SYNC_SESSIONS_DIR }
               else { Join-Path $AppData 'Claude\claude-code-sessions' }
$DefaultRoot = if ($env:CLAUDE_SYNC_DEFAULT_ROOT) { $env:CLAUDE_SYNC_DEFAULT_ROOT }
               else { Join-Path $AppData 'Claude' }
$ProfilesDir = if ($env:CLAUDE_SYNC_PROFILES_DIR) { $env:CLAUDE_SYNC_PROFILES_DIR }
               else { Join-Path $AppData 'Claude Profiles' }
$CanonicalDir = if ($env:CLAUDE_SYNC_HOME) { $env:CLAUDE_SYNC_HOME }
                else { Join-Path $HOME '.claude\scripts' }

$CanonicalPath      = Join-Path $CanonicalDir 'claude-sync.ps1'
$LogPath            = Join-Path $CanonicalDir 'claude-sync.log'
$BackupsDir         = Join-Path $CanonicalDir 'backups'
$LedgerPath         = Join-Path $CanonicalDir 'ledger.tsv'
$LedgerAccountsPath = Join-Path $CanonicalDir '.ledger-accounts.tsv'
$McpLedgerPath      = Join-Path $CanonicalDir 'mcp-ledger.tsv'
$RcBegin            = '# >>> claude-sync shortcut >>>'
$RcEnd              = '# <<< claude-sync shortcut <<<'
$TaskName           = 'claude-sync-watcher'
$KeepBackups        = 10

# Backups for one run live in one dir with one manifest, shared by the
# profile config sync and the session plan executor, so -Revert undoes a
# whole run no matter which layer wrote. Created lazily on first write.
$script:RunDir       = $null
$script:ManifestPath = $null

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

function Initialize-RunDir {
    if ($script:RunDir) { return }
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $script:RunDir = Join-Path $BackupsDir "$epoch"
    $script:ManifestPath = Join-Path $script:RunDir 'manifest.tsv'
    New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
    if (-not (Test-Path -LiteralPath $script:ManifestPath)) {
        [System.IO.File]::WriteAllText($script:ManifestPath, '')
    }
}

function Add-ManifestRow {
    param([string]$Row)
    [System.IO.File]::AppendAllText($script:ManifestPath, $Row + "`n")
}

function Get-AccountDirs {
    # One UUID folder per account. Skip non-account dirs like "_shared"
    # (left behind by other sync experiments/tools); they are not accounts
    # and must never be written into.
    @(Get-ChildItem -Path $SessionsDir -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notlike '_*' })
}

# ---------- profile customization sync ------------------------------------
function Get-DataRoots {
    # Every Claude data dir on this machine: the default one, plus one per
    # profile when a multi-profile launcher (claude-deck) is in use. The
    # default root comes first so its definitions win union conflicts.
    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add($DefaultRoot)
    if (Test-Path -LiteralPath $ProfilesDir) {
        foreach ($d in @(Get-ChildItem -Path $ProfilesDir -Directory -ErrorAction SilentlyContinue)) {
            $roots.Add($d.FullName)
        }
    }
    return ,$roots
}

function ConvertTo-CanonicalJson {
    # Stable one-line rendering used ONLY to compare two server definitions,
    # mirroring the macOS script's JSON.stringify comparison (property order
    # as parsed; two configs that agree byte-for-byte compare equal).
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Compress -Depth 64)
}

function Read-McpLedger {
    # One synced-everywhere server name per line. A name here but missing
    # from some profile now = the user removed it there, so it is removed
    # everywhere. A name absent from here = new, so it is added everywhere.
    # Without this file no MCP removal can ever propagate.
    $names = @{}
    if (-not (Test-Path -LiteralPath $McpLedgerPath)) { return $names }
    foreach ($line in @(Get-Content -LiteralPath $McpLedgerPath -ErrorAction SilentlyContinue)) {
        if ($line) { $names[$line] = $true }
    }
    return $names
}

function Sync-McpServers {
    # Reconcile the mcpServers block of claude_desktop_config.json across
    # every root; every other key of each file is preserved. Decisions, per
    # server name across all configs:
    #   - name in the ledger but missing from >=1 config -> removed
    #     everywhere (only when deletes are on; with -NoDeletes the missing
    #     copy is re-added instead, which is exactly the restore path),
    #   - definitions differ -> the one from the newest-mtime config wins
    #     and overwrites the rest (tie: the default root, listed first, wins),
    #   - name missing from a config -> added there.
    # The plan is computed once in memory and then applied, so narration and
    # writes can never disagree on the decision logic.
    param($Roots, [bool]$Deletes)

    $cfgs = New-Object System.Collections.Generic.List[object]
    foreach ($root in $Roots) {
        $cfgPath = Join-Path $root 'claude_desktop_config.json'
        if (-not (Test-Path -LiteralPath $cfgPath)) {
            if ($DryRun) { continue }
            try { [System.IO.File]::WriteAllText($cfgPath, "{}`n") } catch { continue }
        }
        $raw = [System.IO.File]::ReadAllText($cfgPath)
        if (-not $raw.Trim()) { $raw = '{}' }
        $json = $null
        try { $json = ConvertFrom-Json $raw } catch {
            Out-Sync "MCP servers: not valid JSON, profile sync skipped: $cfgPath"
            return
        }
        $mt = [long]([DateTimeOffset](Get-Item -LiteralPath $cfgPath).LastWriteTimeUtc).ToUnixTimeSeconds()
        $cfgs.Add(@{ Path = $cfgPath; Json = $json; Mt = $mt })
    }
    if ($cfgs.Count -lt 2) { return }

    $ledger = Read-McpLedger

    # Union pass: pick a winning definition per server name.
    $order    = New-Object System.Collections.Generic.List[string]
    $chosen   = @{}
    $chosenMt = @{}
    $pcount   = @{}
    foreach ($cfg in $cfgs) {
        $mProp = $cfg.Json.PSObject.Properties['mcpServers']
        if (-not $mProp -or $null -eq $mProp.Value) { continue }
        foreach ($prop in @($mProp.Value.PSObject.Properties)) {
            $k = $prop.Name
            if ($pcount.ContainsKey($k)) { $pcount[$k]++ } else { $pcount[$k] = 1 }
            if (-not $chosen.ContainsKey($k)) {
                $chosen[$k] = $prop.Value; $chosenMt[$k] = $cfg.Mt; $order.Add($k)
            } elseif ($cfg.Mt -gt $chosenMt[$k] -and
                      (ConvertTo-CanonicalJson $prop.Value) -ne (ConvertTo-CanonicalJson $chosen[$k])) {
                $chosen[$k] = $prop.Value; $chosenMt[$k] = $cfg.Mt
            }
        }
    }

    $removed = @{}
    if ($Deletes) {
        foreach ($k in $order) {
            if ($ledger.ContainsKey($k) -and $pcount[$k] -lt $cfgs.Count) { $removed[$k] = 1 }
        }
    }

    # Per-config plan: what to add, update, remove.
    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($cfg in $cfgs) {
        $mProp = $cfg.Json.PSObject.Properties['mcpServers']
        $m = if ($mProp) { $mProp.Value } else { $null }
        $add = New-Object System.Collections.Generic.List[string]
        $upd = New-Object System.Collections.Generic.List[string]
        $del = New-Object System.Collections.Generic.List[string]
        foreach ($k in $order) {
            $hasProp = ($null -ne $m -and $null -ne $m.PSObject.Properties[$k])
            if ($removed.ContainsKey($k)) {
                if ($hasProp) { $del.Add($k) }
                continue
            }
            if (-not $hasProp) { $add.Add($k) }
            elseif ((ConvertTo-CanonicalJson $m.$k) -ne (ConvertTo-CanonicalJson $chosen[$k])) { $upd.Add($k) }
        }
        if (($add.Count + $upd.Count + $del.Count) -gt 0) {
            $plans.Add(@{ Cfg = $cfg; Add = $add; Upd = $upd; Del = $del })
        }
    }
    # No changes: nothing to write and (matching the macOS script) the MCP
    # ledger is left as-is; it is refreshed by the runs that do write.
    if ($plans.Count -eq 0) { return }

    if ($DryRun) {
        foreach ($p in $plans) {
            if ($p.Add.Count) { Write-Host ('  would add MCP server(s) [{0}] -> {1}' -f ($p.Add -join ','), $p.Cfg.Path) }
            if ($p.Upd.Count) { Write-Host ('  would update MCP server(s) [{0}] -> {1}' -f ($p.Upd -join ','), $p.Cfg.Path) }
            if ($p.Del.Count) { Write-Host ('  would remove MCP server(s) [{0}] -> {1}' -f ($p.Del -join ','), $p.Cfg.Path) }
        }
        return
    }

    foreach ($p in $plans) {
        $cfg = $p.Cfg
        Initialize-RunDir
        $cfgBackupDir = Join-Path $script:RunDir 'configs'
        New-Item -ItemType Directory -Force -Path $cfgBackupDir | Out-Null
        $backupPath = Join-Path $cfgBackupDir ($cfg.Path -replace '[:\\/]', '_')
        Copy-Item -LiteralPath $cfg.Path -Destination $backupPath

        # Mutate the parsed config in place: existing servers keep their
        # position, new ones are appended, every other key is untouched.
        $mProp = $cfg.Json.PSObject.Properties['mcpServers']
        if (-not $mProp -or $null -eq $mProp.Value) {
            $m = New-Object PSObject
            $cfg.Json | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue $m -Force
        } else {
            $m = $mProp.Value
        }
        foreach ($k in $p.Del) { $m.PSObject.Properties.Remove($k) }
        foreach ($k in $p.Upd) { $m.$k = $chosen[$k] }
        foreach ($k in $p.Add) { $m | Add-Member -NotePropertyName $k -NotePropertyValue $chosen[$k] }

        [System.IO.File]::WriteAllText($cfg.Path, ((ConvertTo-Json -InputObject $cfg.Json -Depth 64) + "`n"))
        Add-ManifestRow ("overwrote`t{0}`t{1}" -f $cfg.Path, $backupPath)

        $parts = @()
        if ($p.Add.Count) { $parts += ('added [{0}]'  -f ($p.Add -join ',')) }
        if ($p.Upd.Count) { $parts += ('updated [{0}]' -f ($p.Upd -join ',')) }
        if ($p.Del.Count) { $parts += ('removed [{0}]' -f ($p.Del -join ',')) }
        Write-Log ('  MCP server(s) {0} -> {1}' -f ($parts -join ', '), $cfg.Path)
    }

    # Persist the post-write "present everywhere" set, atomically (temp file
    # then move) so a crash mid-write never leaves a truncated ledger.
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    $tmp = "$McpLedgerPath.tmp.$PID"
    $fin = New-Object System.Collections.Generic.List[string]
    foreach ($k in $order) { if (-not $removed.ContainsKey($k)) { $fin.Add($k) } }
    if ($fin.Count -eq 0) { [System.IO.File]::WriteAllText($tmp, '') }
    else { [System.IO.File]::WriteAllText($tmp, (($fin -join "`n") + "`n")) }
    Move-Item -LiteralPath $tmp -Destination $McpLedgerPath -Force
}

function Sync-Extensions {
    # Copy installed Desktop Extensions across roots, additively. Best
    # effort: a Claude build that also tracks extensions in per-profile
    # preferences may still want one enable-click in that profile.
    param($Roots)
    $copied = 0
    foreach ($srcRoot in $Roots) {
        $srcExt = Join-Path $srcRoot 'Claude Extensions'
        if (-not (Test-Path -LiteralPath $srcExt)) { continue }
        foreach ($ext in @(Get-ChildItem -Path $srcExt -Directory -ErrorAction SilentlyContinue)) {
            foreach ($dstRoot in $Roots) {
                if ($dstRoot -eq $srcRoot) { continue }
                $dst = Join-Path (Join-Path $dstRoot 'Claude Extensions') $ext.Name
                if (Test-Path -LiteralPath $dst) { continue }
                if ($DryRun) {
                    Write-Host ('  would copy extension {0} -> {1}' -f $ext.Name, (Split-Path -Leaf $dstRoot))
                    $copied++
                    continue
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                Copy-Item -LiteralPath $ext.FullName -Destination $dst -Recurse
                Initialize-RunDir
                Add-ManifestRow ("created`t$dst")
                $copied++
            }
        }
    }
    if ($copied -gt 0 -and -not $DryRun) {
        Write-Log "Extensions: $copied copied across profiles."
    }
}

# Preference keys that are per-profile window/session STATE rather than
# settings: syncing them would cross-contaminate what each window has open.
$script:PrefsNoSync = @('launchPreviewPersistedWorkspaces', 'launchPreviewSessionScopedSessions')

function Sync-Preferences {
    # Reconcile the "preferences" block of claude_desktop_config.json across
    # every root, so a setting changed in one profile reaches all of them.
    # ADD-ONLY on purpose: a key present in any config is propagated to the
    # rest and nothing is ever deleted, so a profile that has never been
    # opened (and therefore has no preferences at all) can never blank a
    # setting everywhere. On a genuine conflict the newest-mtime config wins,
    # which is what makes "the last change I made" the one that spreads.
    # Per-account maps (*ByAccount) merge entry by entry, so switching a
    # setting on for one account never drops another account's entry -- the
    # reason a profile could look "off" even when the flag was on elsewhere.
    param($Roots)

    $cfgs = New-Object System.Collections.Generic.List[object]
    foreach ($root in $Roots) {
        $cfgPath = Join-Path $root 'claude_desktop_config.json'
        if (-not (Test-Path -LiteralPath $cfgPath)) { continue }
        $raw = [System.IO.File]::ReadAllText($cfgPath)
        if (-not $raw.Trim()) { $raw = '{}' }
        $json = $null
        try { $json = ConvertFrom-Json $raw } catch {
            Out-Sync "Preferences: not valid JSON, preference sync skipped: $cfgPath"
            return
        }
        $mt = [long]([DateTimeOffset](Get-Item -LiteralPath $cfgPath).LastWriteTimeUtc).ToUnixTimeSeconds()
        $cfgs.Add(@{ Path = $cfgPath; Json = $json; Mt = $mt })
    }
    if ($cfgs.Count -lt 2) { return }

    # Winner per key. Plain keys: newest mtime wins. Per-account maps:
    # accumulated entry by entry, newest mtime wins per account.
    $order    = New-Object System.Collections.Generic.List[string]
    $chosen   = @{}
    $chosenMt = @{}
    $acctVal  = @{}
    $acctMt   = @{}
    foreach ($cfg in $cfgs) {
        $pProp = $cfg.Json.PSObject.Properties['preferences']
        if (-not $pProp -or $null -eq $pProp.Value) { continue }
        foreach ($prop in @($pProp.Value.PSObject.Properties)) {
            $k = $prop.Name
            if ($script:PrefsNoSync -contains $k) { continue }
            if ($k -like '*ByAccount') {
                if (-not $acctVal.ContainsKey($k)) {
                    $acctVal[$k] = @{}; $acctMt[$k] = @{}; $order.Add($k)
                }
                if ($null -ne $prop.Value) {
                    foreach ($e in @($prop.Value.PSObject.Properties)) {
                        if ((-not $acctVal[$k].ContainsKey($e.Name)) -or ($cfg.Mt -gt $acctMt[$k][$e.Name])) {
                            $acctVal[$k][$e.Name] = $e.Value
                            $acctMt[$k][$e.Name]  = $cfg.Mt
                        }
                    }
                }
                continue
            }
            if (-not $chosen.ContainsKey($k)) {
                $chosen[$k] = $prop.Value; $chosenMt[$k] = $cfg.Mt; $order.Add($k)
            } elseif ($cfg.Mt -gt $chosenMt[$k] -and
                      (ConvertTo-CanonicalJson $prop.Value) -ne (ConvertTo-CanonicalJson $chosen[$k])) {
                $chosen[$k] = $prop.Value; $chosenMt[$k] = $cfg.Mt
            }
        }
    }
    # Materialize the merged per-account maps as plain objects.
    foreach ($k in @($acctVal.Keys)) {
        $obj = New-Object PSObject
        foreach ($a in @($acctVal[$k].Keys | Sort-Object)) {
            $obj | Add-Member -NotePropertyName $a -NotePropertyValue $acctVal[$k][$a]
        }
        $chosen[$k] = $obj
    }
    if ($order.Count -eq 0) { return }

    # Per-config plan: keys that are missing there or differ from the winner.
    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($cfg in $cfgs) {
        $pProp = $cfg.Json.PSObject.Properties['preferences']
        $p = if ($pProp) { $pProp.Value } else { $null }
        $set = New-Object System.Collections.Generic.List[string]
        foreach ($k in $order) {
            $has = ($null -ne $p -and $null -ne $p.PSObject.Properties[$k])
            if (-not $has) { $set.Add($k) }
            elseif ((ConvertTo-CanonicalJson $p.$k) -ne (ConvertTo-CanonicalJson $chosen[$k])) { $set.Add($k) }
        }
        if ($set.Count -gt 0) { $plans.Add(@{ Cfg = $cfg; Set = $set }) }
    }
    if ($plans.Count -eq 0) { return }

    if ($DryRun) {
        foreach ($pl in $plans) {
            Write-Host ('  would sync preference(s) [{0}] -> {1}' -f (($pl.Set | Select-Object -First 6) -join ','), $pl.Cfg.Path)
        }
        return
    }

    foreach ($pl in $plans) {
        $cfg = $pl.Cfg
        Initialize-RunDir
        $cfgBackupDir = Join-Path $script:RunDir 'configs'
        New-Item -ItemType Directory -Force -Path $cfgBackupDir | Out-Null
        $backupPath = Join-Path $cfgBackupDir ($cfg.Path -replace '[:\\/]', '_')
        # The mcpServers pass may already have backed this file up this run;
        # that copy is the pre-run original, so never overwrite it.
        if (-not (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $cfg.Path -Destination $backupPath
        }

        $pProp = $cfg.Json.PSObject.Properties['preferences']
        if (-not $pProp -or $null -eq $pProp.Value) {
            $p = New-Object PSObject
            $cfg.Json | Add-Member -NotePropertyName 'preferences' -NotePropertyValue $p -Force
        } else {
            $p = $pProp.Value
        }
        foreach ($k in $pl.Set) {
            if ($null -ne $p.PSObject.Properties[$k]) { $p.$k = $chosen[$k] }
            else { $p | Add-Member -NotePropertyName $k -NotePropertyValue $chosen[$k] }
        }

        [System.IO.File]::WriteAllText($cfg.Path, ((ConvertTo-Json -InputObject $cfg.Json -Depth 64) + "`n"))
        Add-ManifestRow ("overwrote`t{0}`t{1}" -f $cfg.Path, $backupPath)
        Write-Log ('  preference(s) synced [{0}] -> {1}' -f (($pl.Set | Select-Object -First 6) -join ','), $cfg.Path)
    }
}

function Sync-Profiles {
    # Orchestrates the profile layer. Fast, runs before the session
    # machinery, and independent of it (profiles exist even with a single
    # account). With no "Claude Profiles" dir there is one root and every
    # step returns immediately.
    param([bool]$Deletes)
    $roots = Get-DataRoots
    if ($roots.Count -lt 2) { return }
    Sync-McpServers -Roots $roots -Deletes $Deletes
    Sync-Preferences -Roots $roots
    Sync-Extensions -Roots $roots
}

# ---------- session ledger -------------------------------------------------
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
        if ($parts[1] -notmatch '^\d+$') { continue }
        $ledger[$parts[0]] = [long]$parts[1]
    }
    return $ledger
}

# Companion file: the account names that counted as "everywhere" when the
# ledger was last written (one name per line). An account added AFTER that
# write must not make every ledgered session look "deleted somewhere", so
# absence is judged only against this recorded set. Missing or empty file =
# fail safe: no deletion candidates at all.
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

function Update-Ledger {
    # Called at the end of EVERY successful non-dry sync, changes or not
    # (the ledger is what makes a future deletion pass able to tell
    # "deleted" apart from "never synced here yet"). Records fname + newest
    # lastActivityAt for every session present, after this run's writes, in
    # every account. Reads the post-write state from disk rather than
    # trusting the pre-run inventory, so a run that only partially completes
    # cannot write a false row. Written atomically (temp file + move).
    param($Accounts)
    $post = @{}
    foreach ($account in $Accounts) {
        foreach ($org in @(Get-ChildItem -Path $account.FullName -Directory -ErrorAction SilentlyContinue)) {
            foreach ($f in @(Get-ChildItem -Path $org.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue)) {
                $raw = [System.IO.File]::ReadAllText($f.FullName)
                $ts = [long]0
                if ($raw -match '"lastActivityAt":(\d+)') { $ts = [long]$Matches[1] }
                if (-not $post.ContainsKey($f.Name)) {
                    $post[$f.Name] = @{ MaxTs = $ts; Accts = @{} }
                }
                $e = $post[$f.Name]
                if ($ts -gt $e.MaxTs) { $e.MaxTs = $ts }
                $e.Accts[$account.Name] = $true
            }
        }
    }

    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    $tmp = "$LedgerPath.tmp.$PID"
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($fname in ($post.Keys | Sort-Object)) {
        if ($post[$fname].Accts.Count -ge $Accounts.Count) {
            $lines.Add("$fname`t$($post[$fname].MaxTs)")
        }
    }
    if ($lines.Count -eq 0) { [System.IO.File]::WriteAllText($tmp, '') }
    else { [System.IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n")) }
    Move-Item -LiteralPath $tmp -Destination $LedgerPath -Force

    # Record which accounts this ledger considers "everywhere", so a future
    # deletion pass can tell a brand-new account (not part of this set)
    # apart from an account that genuinely had a ledgered session removed.
    $tmpAcct = "$LedgerAccountsPath.tmp.$PID"
    $acctLines = New-Object System.Collections.Generic.List[string]
    foreach ($account in $Accounts) { $acctLines.Add($account.Name) }
    if ($acctLines.Count -eq 0) { [System.IO.File]::WriteAllText($tmpAcct, '') }
    else { [System.IO.File]::WriteAllText($tmpAcct, (($acctLines -join "`n") + "`n")) }
    Move-Item -LiteralPath $tmpAcct -Destination $LedgerAccountsPath -Force
}

# ---------- sync core ------------------------------------------------------
# Two passes over the whole tree, O(total files): every index file is read
# exactly once and all copies are planned from that inventory (never
# src-account x dst-account loops).
function Get-Inventory {
    # Pass 1: one row per <account>\<org>\local_*.json. The index JSON is
    # compact and single-line; regex-extract the two fields sync decisions
    # need (lastActivityAt, isArchived).
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
                    Org     = $org.Name
                })
            }
        }
    }
    return ,$inv
}

function Invoke-Sync {
    $doDeletes = -not $NoDeletes

    # Profile customization first: fast, and independent of the session
    # machinery (profiles exist even with a single account or no sessions).
    Sync-Profiles -Deletes $doDeletes

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

    $inventory = Get-Inventory -Accounts $accounts

    # Pass 2: reduce per session. Winner = copy with max lastActivityAt
    # (ties: first seen). ArchOR = archived in at least one account (the OR
    # is deliberate: archived in even one account means archived everywhere;
    # known accepted caveat: un-archiving cannot propagate). PresentIn and
    # MaxTs feed the deletion pass.
    $sessions  = @{}
    $invByPath = @{}
    $invByName = @{}
    foreach ($e in $inventory) {
        $invByPath[$e.Path] = $e
        if (-not $invByName.ContainsKey($e.Fname)) {
            $invByName[$e.Fname] = New-Object System.Collections.Generic.List[object]
        }
        $invByName[$e.Fname].Add($e)
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

    # ---------- delete propagation (default; skipped by -NoDeletes) -------
    # A session qualifies for deletion everywhere iff: it is in the ledger
    # (fully synced across all accounts once), it is now absent from at
    # least one account that BOTH was part of the last ledger write AND
    # still exists on disk, and no surviving copy is newer than the ledger's
    # recorded time (otherwise it was used after the last full sync, so the
    # deletion may predate that activity: keep it and say why). The
    # intersection matters: judging absence against a brand-new account
    # would qualify the whole history for deletion, and judging it against
    # a vanished account would delete everything idle since the last sync.
    # Empty intersection = no candidates: fail safe. The activity guard
    # still looks at ALL current copies, including ones in new accounts.
    $deleteRows      = New-Object System.Collections.Generic.List[object]
    $deletedSessions = @{}
    if ($doDeletes) {
        $ledger = Get-Ledger
        $recordedAccounts = Get-LedgerAccounts
        $absenceAccounts = New-Object System.Collections.Generic.List[string]
        foreach ($account in $accounts) {
            if ($recordedAccounts.ContainsKey($account.Name)) { $absenceAccounts.Add($account.Name) }
        }
        foreach ($fname in @($sessions.Keys)) {
            if (-not $ledger.ContainsKey($fname)) { continue }   # never fully synced: never delete
            $s = $sessions[$fname]
            $absentSomewhere = $false
            foreach ($name in $absenceAccounts) {
                if (-not $s.PresentIn.ContainsKey($name)) { $absentSomewhere = $true; break }
            }
            if (-not $absentSomewhere) { continue }              # present in every counted account
            if ($s.MaxTs -gt $ledger[$fname]) {
                Out-Sync "  Kept $fname everywhere: a surviving copy is newer than the last full sync, so the deletion may predate that activity."
                continue
            }
            foreach ($e in $invByName[$fname]) {
                $deleteRows.Add([PSCustomObject]@{
                    Verb = 'delete'; Fname = $fname; Dst = $e.Path
                    Account = $e.Account; Org = $e.Org
                })
            }
            $deletedSessions[$fname] = 1
            # Deletion candidates must never be resurrected by this same
            # run: drop them before the distribute plan ever sees them.
            $sessions.Remove($fname)
        }
    }

    # ---------- plan ------------------------------------------------------
    # Cross every destination org dir with every surviving session, decide
    # from the inventory alone (files are never re-read here). Sessions are
    # distributed into every org folder of every account, same as the macOS
    # script: the index JSON carries no org identity, and Claude shows one
    # merged list per account.
    $planRows = New-Object System.Collections.Generic.List[object]
    foreach ($account in $accounts) {
        foreach ($org in @(Get-ChildItem -Path $account.FullName -Directory -ErrorAction SilentlyContinue)) {
            foreach ($fname in $sessions.Keys) {
                $s = $sessions[$fname]
                $dst = Join-Path $org.FullName $fname
                if (-not $invByPath.ContainsKey($dst)) {
                    $planRows.Add([PSCustomObject]@{
                        Verb = 'create'; Fname = $fname; Dst = $dst
                        Account = $account.Name; Org = $org.Name
                        IsNew = $true; IsUpd = $false; IsArch = $false
                    })
                    continue
                }
                $d = $invByPath[$dst]
                $stale     = ($d.Ts -lt $s.WinnerTs)
                $needsArch = ($s.ArchOR -and -not $d.Arch)
                if (-not $stale -and -not $needsArch) { continue }
                $planRows.Add([PSCustomObject]@{
                    Verb = 'overwrite'; Fname = $fname; Dst = $dst
                    Account = $account.Name; Org = $org.Name
                    IsNew = $false; IsUpd = $stale; IsArch = $needsArch
                })
            }
        }
    }
    foreach ($row in $deleteRows) { $planRows.Add($row) }

    # ---------- nothing to do ----------------------------------------------
    if ($planRows.Count -eq 0) {
        $msg = "Everything already in sync. $($sessions.Count) total sessions across $($accounts.Count) accounts."
        if ($DryRun) {
            Write-Host "Dry run: everything already in sync. $($sessions.Count) total sessions across $($accounts.Count) accounts."
        } else {
            Write-Log $msg
            Update-Ledger -Accounts $accounts
            if ($script:RunDir) {
                # The profile layer wrote even though sessions were clean.
                Write-Log "Sync complete. Backup: $($script:RunDir) (claude-sync -Revert undoes this run)"
            }
        }
        return 0
    }

    # ---------- dry run -----------------------------------------------------
    if ($DryRun) {
        Write-Host "Dry run across $($accounts.Count) accounts. Planned actions:"
        foreach ($row in $planRows) {
            Write-Host "  would $($row.Verb): $($row.Dst)"
        }
        Write-PlanSummary -PlanRows $planRows -Sessions $sessions -Accounts $accounts
        Write-Host 'Nothing was written.'
        return 0
    }

    # ---------- execute -----------------------------------------------------
    Write-Log "Syncing sessions across $($accounts.Count) accounts..."
    Initialize-RunDir

    # Staging: sessions archived somewhere whose winner says
    # "isArchived":false get a flipped copy; that copy becomes canonical.
    # The winner's LastWriteTime is kept so copy mtimes stay meaningful.
    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-sync-staging-' + [guid]::NewGuid().ToString('N'))
    $stagedAny = $false
    foreach ($fname in @($sessions.Keys)) {
        $s = $sessions[$fname]
        $s.Canonical = $s.WinnerPath
        if ($s.ArchOR -and -not $s.WinnerArch) {
            $raw = [System.IO.File]::ReadAllText($s.WinnerPath)
            if ($raw.Contains('"isArchived":false')) {
                if (-not $stagedAny) {
                    New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
                    $stagedAny = $true
                }
                $stagedPath = Join-Path $stagingDir $fname
                [System.IO.File]::WriteAllText($stagedPath, $raw.Replace('"isArchived":false', '"isArchived":true'))
                (Get-Item -LiteralPath $stagedPath).LastWriteTime = (Get-Item -LiteralPath $s.WinnerPath).LastWriteTime
                $s.Canonical = $stagedPath
            }
        }
    }

    try {
        foreach ($row in $planRows) {
            if ($row.Verb -eq 'create') {
                if (-not (Test-Path -LiteralPath $row.Dst)) {
                    Copy-Item -LiteralPath $sessions[$row.Fname].Canonical -Destination $row.Dst
                    Add-ManifestRow ("created`t$($row.Dst)")
                    continue
                }
                # Destination appeared after the inventory pass: fall through
                # to the backed-up overwrite below.
            }
            if ($row.Verb -eq 'delete') {
                # A dst that vanished between planning and here is done.
                if (Test-Path -LiteralPath $row.Dst) {
                    $backupPath = Join-Path (Join-Path (Join-Path $script:RunDir $row.Account) $row.Org) $row.Fname
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
                    Copy-Item -LiteralPath $row.Dst -Destination $backupPath
                    Remove-Item -LiteralPath $row.Dst -Force
                    Add-ManifestRow ("deleted`t$($row.Dst)`t$backupPath")
                }
                continue
            }
            # Overwrite: back the current file up first (mirroring
            # <account>\<org>\ so -Revert can put it back).
            $backupPath = Join-Path (Join-Path (Join-Path $script:RunDir $row.Account) $row.Org) $row.Fname
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
            Copy-Item -LiteralPath $row.Dst -Destination $backupPath
            Copy-Item -LiteralPath $sessions[$row.Fname].Canonical -Destination $row.Dst -Force
            Add-ManifestRow ("overwrote`t$($row.Dst)`t$backupPath")
        }
    }
    finally {
        if ($stagedAny) { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Prune old backup runs (keep the newest N, reverted ones included).
    if (Test-Path $BackupsDir) {
        $runs = @(Get-ChildItem -Path $BackupsDir -Directory |
                  Where-Object { $_.Name -match '^\d+(\.reverted)?$' } |
                  Sort-Object { [long](($_.Name -replace '\.reverted$', '')) } -Descending)
        if ($runs.Count -gt $KeepBackups) {
            foreach ($old in $runs[$KeepBackups..($runs.Count - 1)]) {
                Remove-Item -LiteralPath $old.FullName -Recurse -Force
            }
        }
    }

    Write-PlanSummary -PlanRows $planRows -Sessions $sessions -Accounts $accounts
    Update-Ledger -Accounts $accounts
    Write-Log "Sync complete. Backup: $($script:RunDir) (claude-sync -Revert undoes this run)"
    return 0
}

function Write-PlanSummary {
    # Honest counts: unique sessions, never file copies. "3 new, 5 updated"
    # means 3 sessions and 5 sessions, not the 36 files behind them.
    param($PlanRows, $Sessions, $Accounts)

    $acctNew = @{}; $acctUpd = @{}; $acctDel = @{}
    $newS = @{}; $updS = @{}; $arcS = @{}; $delS = @{}
    foreach ($row in $PlanRows) {
        $ak = $row.Account
        if (-not $acctNew.ContainsKey($ak)) { $acctNew[$ak] = @{}; $acctUpd[$ak] = @{}; $acctDel[$ak] = @{} }
        if ($row.Verb -eq 'create')      { $acctNew[$ak][$row.Fname] = 1; $newS[$row.Fname] = 1 }
        elseif ($row.Verb -eq 'delete')  { $acctDel[$ak][$row.Fname] = 1; $delS[$row.Fname] = 1 }
        else {
            if ($row.IsUpd) { $acctUpd[$ak][$row.Fname] = 1; $updS[$row.Fname] = 1 }
            if ($row.IsArch) { $arcS[$row.Fname] = 1 }
        }
    }
    foreach ($ak in ($acctNew.Keys | Sort-Object)) {
        $line = '  {0}: +{1} new, {2} updated' -f $ak, $acctNew[$ak].Count, $acctUpd[$ak].Count
        if ($acctDel[$ak].Count -gt 0) { $line += ', -{0} deleted' -f $acctDel[$ak].Count }
        Out-Sync $line
    }

    $summary = '{0} new session(s) appeared somewhere, {1} session(s) updated to a newer state, {2} session(s) archived everywhere (was archived in at least one account)' -f `
        $newS.Count, $updS.Count, $arcS.Count
    if ($delS.Count -gt 0) {
        $summary += ', {0} session(s) deleted everywhere (deleted in at least one account)' -f $delS.Count
    }
    Out-Sync "$summary. $($Sessions.Count) total sessions across $($Accounts.Count) accounts."
}

# ---------- revert ---------------------------------------------------------
function Invoke-Revert {
    # Undo the most recent sync run: delete files it created, restore files
    # it overwrote or deleted, then mark the backup dir .reverted so a
    # second -Revert targets the run before it.
    $runs = @()
    if (Test-Path $BackupsDir) {
        $runs = @(Get-ChildItem -Path $BackupsDir -Directory |
                  Where-Object { $_.Name -match '^\d+$' } |
                  Sort-Object { [long]$_.Name } -Descending)
    }
    if ($runs.Count -eq 0) {
        Write-Host "No backups found ($BackupsDir). Nothing to revert."
        return 1
    }
    $run = $null
    foreach ($candidate in $runs) {
        if (Test-Path (Join-Path $candidate.FullName 'manifest.tsv')) { $run = $candidate; break }
    }
    if (-not $run) {
        Write-Host 'No backup run left to revert.'
        return 1
    }
    $manifestPath = Join-Path $run.FullName 'manifest.tsv'

    Write-Log "Reverting sync run $($run.Name)..."
    $removed = 0; $restored = 0; $undeleted = 0
    foreach ($line in @(Get-Content -LiteralPath $manifestPath)) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        switch ($parts[0]) {
            'created' {
                if (Test-Path -LiteralPath $parts[1]) {
                    # Extension rows point at directories; -Recurse handles both.
                    Remove-Item -LiteralPath $parts[1] -Recurse -Force
                    $removed++
                }
            }
            'overwrote' {
                Copy-Item -LiteralPath $parts[2] -Destination $parts[1] -Force
                $restored++
            }
            'deleted' {
                # The file does not exist at revert time (that is the point
                # of a delete row); a plain copy-back is correct.
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $parts[1]) | Out-Null
                Copy-Item -LiteralPath $parts[2] -Destination $parts[1] -Force
                $undeleted++
            }
        }
    }
    Rename-Item -LiteralPath $run.FullName -NewName ($run.Name + '.reverted')
    Write-Log "Reverted: removed $removed created file(s), restored $restored overwritten file(s), restored $undeleted deleted file(s)."
    Write-Log "Backup kept at $($run.Name).reverted. Run -Revert again to undo the previous run."
    return 0
}

# ---------- watcher (hands-off mode) ---------------------------------------
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
        # Fresh run state per iteration (one backup run dir per sync).
        $script:RunDir = $null
        $script:ManifestPath = $null
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
    Write-Host 'Auto-sync enabled. Sessions sync every time Claude Desktop quits (deletes included).'
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

# ---------- install / uninstall --------------------------------------------
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
    Write-Host 'To delete the script, log, ledgers and backups too:'
    Write-Host "  Remove-Item `"$CanonicalPath`", `"$LogPath`", `"$LedgerPath`", `"$LedgerAccountsPath`", `"$McpLedgerPath`"; Remove-Item -Recurse `"$BackupsDir`""
}

# ---------- status / help ---------------------------------------------------
function Show-Status {
    Write-Host "claude-sync v$ScriptVersion"
    $roots = Get-DataRoots
    if ($roots.Count -gt 1) {
        Write-Host ("Data dirs: {0} (default + {1} profile(s) in 'Claude Profiles')" -f $roots.Count, ($roots.Count - 1))
        foreach ($root in $roots) {
            $cfg = Join-Path $root 'claude_desktop_config.json'
            $n = 0
            if (Test-Path -LiteralPath $cfg) {
                try {
                    $json = ConvertFrom-Json ([System.IO.File]::ReadAllText($cfg))
                    $mProp = $json.PSObject.Properties['mcpServers']
                    if ($mProp -and $null -ne $mProp.Value) { $n = @($mProp.Value.PSObject.Properties).Count }
                } catch { $n = '?' }
            }
            Write-Host ('  {0}: {1} MCP server(s)' -f (Split-Path -Leaf $root), $n)
        }
    }
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
        # 'Sync complete' is v3's completion line; 'Done.' covers logs from
        # the v1/v2 scripts so history stays readable.
        $doneLines = @(Get-Content -Path $LogPath -ErrorAction SilentlyContinue |
                       Where-Object { $_ -match '\] (Sync complete|Done\.)' })
        if ($doneLines.Count -gt 0 -and $doneLines[$doneLines.Count - 1] -match '^\[([^\]]+)\]') {
            $lastSync = $Matches[1]
        }
    }
    if ($lastSync) { Write-Host "Last sync: $lastSync" } else { Write-Host 'Last sync: never' }
    $runCount = 0
    if (Test-Path $BackupsDir) {
        $runCount = @(Get-ChildItem -Path $BackupsDir -Directory).Count
    }
    Write-Host "Backups: $runCount stored run(s) (use -Revert to undo the newest)"
}

function Show-Help {
    Write-Host @"
claude-sync v$ScriptVersion
Make local Claude Code sessions visible across all Claude Desktop accounts,
and keep customization (MCP servers, Desktop Extensions) in sync across
profiles (claude-deck). Newest session state wins; archived-in-one means
archived-everywhere; overwrites are backed up and revertible. Deletions
propagate by default: delete a session in any account (or an MCP server in
any profile) and the next sync deletes it everywhere, after a backup. MCP
server edits propagate too: when profiles disagree on a server's
definition, the profile config edited most recently wins. Logins, cookies,
and preferences are never touched.

Usage: claude-sync [command]   (--gnu-style spellings work too)

  (no command)     Run the sync (deletions propagate; see -NoDeletes).
  -DryRun          Show what a sync would do, write nothing.
  -NoDeletes       Sync WITHOUT propagating deletions. Anything deleted on
                   one side but alive elsewhere is copied back instead:
                   use this to restore a session or MCP server you
                   deleted by mistake (before the deletion has synced).
  -Revert          Undo the most recent sync run from its backup.
  -Status          Show detected accounts, session counts, install state.
  -Install         Copy this script to ~\.claude\scripts\ and register the
                   'claude-sync' command in your PowerShell profile.
                   Re-run to update.
  -Uninstall       Remove the command and the auto-sync task (if enabled).
  -AutoInstall     Auto-sync every time Claude Desktop quits (per-user
                   Scheduled Task, no admin rights).
  -AutoUninstall   Disable auto-sync.
  -Version         Print version.
  -Help            This text.

Before the first sync: log in to the new account in Claude Desktop, start
one throwaway Claude Code session ('hi' is enough), quit Claude, then sync.

Warning: deletion propagation removes files after a backup, but a mistake
can still cost you a session across every account. -Revert undoes the
last run; -DryRun previews what would be deleted; -NoDeletes restores
a not-yet-propagated deletion from the surviving copies.
"@
}

# ---------- dispatcher -------------------------------------------------------
# Map GNU-style spellings onto the switches, so the macOS muscle memory
# (claude-sync --dry-run --no-deletes) works here too.
$flagMap = @{
    '--dry-run' = 'DryRun'; '--no-deletes' = 'NoDeletes'; '--revert' = 'Revert'
    '--status' = 'Status'; '--install' = 'Install'; '--uninstall' = 'Uninstall'
    '--auto-install' = 'AutoInstall'; '--auto-uninstall' = 'AutoUninstall'
    '--watch' = 'Watch'; '--version' = 'Version'; '-v' = 'Version'
    '--help' = 'Help'; '-h' = 'Help'
}
$badArg = $false
foreach ($arg in @($Rest)) {
    if ($null -eq $arg -or $arg -eq '') { continue }
    $key = $arg.ToLowerInvariant()
    if ($flagMap.ContainsKey($key)) {
        Set-Variable -Name $flagMap[$key] -Value ([switch]$true)
    } else {
        $badArg = $true
    }
}

if     ($badArg)        { Show-Help; exit 1 }
elseif ($Help)          { Show-Help }
elseif ($Version)       { Write-Host "claude-sync v$ScriptVersion" }
elseif ($Install)       { Install-ClaudeSync }
elseif ($Uninstall)     { Uninstall-ClaudeSync }
elseif ($AutoInstall)   { exit (Install-AutoSync) }
elseif ($AutoUninstall) { exit (Uninstall-AutoSync) }
elseif ($Watch)         { Invoke-Watch }
elseif ($Status)        { Show-Status }
elseif ($Revert)        { exit (Invoke-Revert) }
else                    { exit (Invoke-Sync) }
