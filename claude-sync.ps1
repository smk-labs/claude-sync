# claude-sync: make local Claude Code sessions visible across all your
# Claude Desktop accounts on this PC.
#
# Claude Desktop keeps a separate Claude Code session index per account+org
# (one <account-uuid>\<org-uuid> folder under
# %APPDATA%\Claude\claude-code-sessions, small local_*.json files). Switch
# account or org and your session list looks empty, even though every
# transcript is still on disk in ~\.claude\projects.
#
# v4 (Windows) fixes this STRUCTURALLY instead of copying files around:
#   - UNIFY (one-time, needs Claude fully closed): the union of every
#     <account>\<org>'s local_*.json moves into one real folder,
#     claude-code-sessions\_shared, and every <account>\<org> folder is
#     replaced by a directory junction to _shared. One physical list;
#     every account and org reads and writes the same files; new sessions
#     appear everywhere instantly; nothing is ever copied again.
#     Union conflicts resolve like v3 did: newest lastActivityAt wins,
#     archived-in-one means archived-everywhere. The whole tree is
#     backed up first (junction-aware) and -Revert restores it fully.
#   - SELF-HEAL (every run, safe with Claude open): scans every transcript
#     in ~\.claude\projects and, for any session that has a transcript but
#     no list entry in _shared (the app sometimes never writes one after a
#     restart or a rewound session), generates a minimal entry from the
#     transcript itself (title from the first user message or the recorded
#     custom title; cwd, timestamps and model read from the transcript).
#     Existing entries are never edited or deleted; transcripts are never
#     touched. A heal ledger (heal-ledger.tsv) remembers every session id
#     ever listed, so an entry the user deletes in the app is never
#     resurrected from its transcript.
#   - NEWCOMERS: when the app later creates a fresh real <account>\<org>
#     folder (first login of a new account/org), the next run with Claude
#     closed absorbs its entries into _shared and junctions it too.
# The v3 copy machinery (winner distribution, deletion ledger) is gone for
# sessions: with one physical list there is nothing to reconcile and a
# delete in the app is already a delete everywhere. ledger.tsv is read one
# last time during UNIFY (its ids seed the heal ledger, so sessions deleted
# after their last full v3 sync are not resurrected) and never written
# again. The macOS script (claude-sync.sh) still implements the v3 copy
# design; this junction design is Windows-only for now.
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
# (a parallel index tree that appeared in mid-2026 builds). Its semantics
# are unknown; restructuring it blindly could corrupt agent state.
# Revisit once Claude ships whatever it is for.
#
# Safety notes for the structural work (learned the hard way elsewhere):
#   - A junction is removed with the non-recursive Directory.Delete (or an
#     rmdir), NEVER Remove-Item -Recurse: recursing through a reparse point
#     deletes the TARGET's contents, i.e. the shared index itself.
#   - Restructure and structural revert refuse to run while Claude Desktop
#     is up. Detection is by ExecutablePath (MSIX \WindowsApps\Claude_* or
#     legacy Squirrel \AnthropicClaude\app-*), never by process name: the
#     Claude Code CLI is also a claude.exe and must not count.
#   - Existing list files are only ever regex-scanned, never JSON-parsed:
#     real files exist whose enabledMcpTools map has case-colliding keys
#     that ConvertFrom-Json rejects.
#
# JSON handling uses PowerShell's built-in ConvertFrom-Json/ConvertTo-Json:
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
$ScriptVersion = '4.0.0'

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
$ProjectsDir = if ($env:CLAUDE_SYNC_PROJECTS_DIR) { $env:CLAUDE_SYNC_PROJECTS_DIR }
               else { Join-Path $HOME '.claude\projects' }
$CanonicalDir = if ($env:CLAUDE_SYNC_HOME) { $env:CLAUDE_SYNC_HOME }
                else { Join-Path $HOME '.claude\scripts' }

$CanonicalPath      = Join-Path $CanonicalDir 'claude-sync.ps1'
$LogPath            = Join-Path $CanonicalDir 'claude-sync.log'
$BackupsDir         = Join-Path $CanonicalDir 'backups'
$LedgerPath         = Join-Path $CanonicalDir 'ledger.tsv'
$LedgerAccountsPath = Join-Path $CanonicalDir '.ledger-accounts.tsv'
$McpLedgerPath      = Join-Path $CanonicalDir 'mcp-ledger.tsv'
$HealLedgerPath     = Join-Path $CanonicalDir 'heal-ledger.tsv'
$RcBegin            = '# >>> claude-sync shortcut >>>'
$RcEnd              = '# <<< claude-sync shortcut <<<'
$TaskName           = 'claude-sync-watcher'
$KeepBackups        = 10

# Backups for one run live in one dir with one manifest, shared by the
# profile config sync and the session module, so -Revert undoes a whole
# run no matter which layer wrote. Created lazily on first write.
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
    # Two runs inside the same second must not share a dir: a merged
    # manifest would make one -Revert undo both runs at once.
    while (Test-Path -LiteralPath (Join-Path $BackupsDir "$epoch")) { $epoch++ }
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

function Get-LongDirPath {
    # Expand 8.3 short components (C:\Users\MOHAMM~1\...) of an existing
    # directory path. Windows stores junction targets long-form, so every
    # path we compare against a junction target must be long-form too.
    # Component walk via GetFileSystemEntries: a short name used as the
    # search pattern matches its own directory entry, and the returned
    # path carries the real long name.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        if ($full -notmatch '~') { return $full }
        $root = [System.IO.Path]::GetPathRoot($full)
        $cur = $root.TrimEnd('\')
        foreach ($part in $full.Substring($root.Length).Split('\')) {
            if (-not $part) { continue }
            $hit = @([System.IO.Directory]::GetFileSystemEntries("$cur\", $part))
            if ($hit.Count -ge 1) { $cur = $hit[0] } else { $cur = "$cur\$part" }
        }
        return $cur
    } catch { return $Path }
}

# Canonicalize once: a short-form %APPDATA%/%TEMP% from the environment
# would otherwise make every junction-target comparison fail.
$SessionsDir = Get-LongDirPath -Path $SessionsDir
$SharedDir   = Join-Path $SessionsDir '_shared'

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

# ---------- session module: one _shared index behind junctions -------------
# UNIFY once (Claude closed), then SELF-HEAL every run. See the header
# comment for the design. Everything here is Set-StrictMode clean and
# 5.1-safe; the structural entry points enable strict mode for themselves.

$script:UuidNameRe  = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:LocalNameRe = '^local_([0-9a-fA-F-]{36})\.json$'

function Test-ClaudeDesktopRunning {
    # TRUE iff any live process belongs to the Claude DESKTOP install.
    # Match by ExecutablePath, never by name: the Claude Code CLI is also a
    # claude.exe (under ...\claude-code\<ver>\claude.exe) and must not
    # count, while Desktop and all its Electron children live under the
    # MSIX package dir (or the legacy Squirrel dir). When the sessions dir
    # is overridden to a throwaway tree (tests), the check is skipped: it
    # exists to protect the real tree only. The FORCE_RUNNING hook lets
    # tests exercise the postpone paths; it can only make the tool MORE
    # conservative, never less.
    if ($env:CLAUDE_SYNC_TEST_FORCE_RUNNING) { return $true }
    $realSessions = Get-LongDirPath -Path (Join-Path (Join-Path $AppData 'Claude') 'claude-code-sessions')
    if ($env:CLAUDE_SYNC_SESSIONS_DIR -and ($SessionsDir -ine $realSessions)) { return $false }
    $paths = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop)) {
            if ($p.ExecutablePath) { $paths.Add([string]$p.ExecutablePath) }
        }
    } catch {
        foreach ($p in @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue)) {
            $exe = $null
            try { $exe = $p.Path } catch { $exe = $null }
            if ($exe) { $paths.Add([string]$exe) }
        }
    }
    foreach ($path in $paths) {
        if ($path -match '\\WindowsApps\\Claude_' -or $path -match '\\AnthropicClaude\\app-') { return $true }
    }
    return $false
}

function Remove-DirectorySafe {
    # Junction-aware delete. A reparse point is unlinked with the
    # NON-recursive Directory.Delete, which can never descend into the
    # target (Remove-Item -Recurse through a junction deletes the target's
    # contents -- here that would be the shared index itself). Real dirs are
    # walked manually for the same reason: a real dir may CONTAIN junctions.
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        [System.IO.Directory]::Delete($Path, $false)
    } else {
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            if ($child.PSIsContainer) { Remove-DirectorySafe -Path $child.FullName }
            else { Remove-Item -LiteralPath $child.FullName -Force }
        }
        Remove-Item -LiteralPath $Path -Force
    }
    if (Test-Path -LiteralPath $Path) { throw "Failed to remove: $Path" }
}

function Test-JunctionTo {
    param([string]$Path, [string]$Target)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
    $t = @($item.Target)
    if ($t.Count -eq 0 -or -not $t[0]) { return $false }
    $got = [string]$t[0]
    if ($got.StartsWith('\\?\')) { $got = $got.Substring(4) }
    $want = $Target
    if ($want.StartsWith('\\?\')) { $want = $want.Substring(4) }
    $want = Get-LongDirPath -Path $want
    return ($got.TrimEnd('\') -ieq $want.TrimEnd('\'))
}

function New-JunctionSafe {
    # New-Item can silently no-op (a lesson from claude-deck), so trust only
    # the re-read: the path must exist, be a reparse point, and resolve to
    # the target. One clear-and-retry, then fail loudly (the unify catch
    # rolls the whole tree back).
    param([string]$Path, [string]$Target)
    try { New-Item -ItemType Junction -Path $Path -Value $Target -ErrorAction Stop | Out-Null } catch { }
    if (-not (Test-JunctionTo -Path $Path -Target $Target)) {
        if (Test-Path -LiteralPath $Path) { Remove-DirectorySafe -Path $Path }
        New-Item -ItemType Junction -Path $Path -Value $Target -ErrorAction Stop | Out-Null
    }
    if (-not (Test-JunctionTo -Path $Path -Target $Target)) {
        throw "Could not create junction: $Path -> $Target"
    }
}

function Copy-TreeSnapshot {
    # Junction-aware recursive copy: junctions become rows in $JunRows
    # (relative path + target), never followed; real files and dirs are
    # copied (Copy-Item keeps file mtimes).
    param([string]$Src, [string]$Dst, [string]$Rel, $JunRows)
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath $Src -File -Force -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Dst $f.Name)
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Src -Directory -Force -ErrorAction SilentlyContinue)) {
        $childRel = if ($Rel) { Join-Path $Rel $d.Name } else { $d.Name }
        if ([bool]($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $t = @($d.Target)
            $tgt = if ($t.Count -gt 0 -and $t[0]) { [string]$t[0] } else { '' }
            $JunRows.Add("$childRel`t$tgt")
        } else {
            Copy-TreeSnapshot -Src $d.FullName -Dst (Join-Path $Dst $d.Name) -Rel $childRel -JunRows $JunRows
        }
    }
}

function Backup-SessionsTree {
    # Full snapshot of the sessions tree into this run's backup dir, plus
    # one 'tree' manifest row, written BEFORE any mutation, so -Revert (and
    # the unify rollback path) can always restore the exact pre-run tree.
    Initialize-RunDir
    $treeDir = Join-Path $script:RunDir 'sessions-tree'
    $junTsv  = "$treeDir.junctions.tsv"
    New-Item -ItemType Directory -Force -Path $treeDir | Out-Null
    $junRows = New-Object System.Collections.Generic.List[string]
    Copy-TreeSnapshot -Src $SessionsDir -Dst $treeDir -Rel '' -JunRows $junRows
    if ($junRows.Count -eq 0) { [System.IO.File]::WriteAllText($junTsv, '') }
    else { [System.IO.File]::WriteAllText($junTsv, (($junRows -join "`n") + "`n")) }
    Add-ManifestRow ("tree`t{0}`t{1}" -f $SessionsDir, $treeDir)
}

function Copy-TreeRestore {
    param([string]$Src, [string]$Dst)
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath $Src -File -Force -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Dst $f.Name) -Force
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Src -Directory -Force -ErrorAction SilentlyContinue)) {
        Copy-TreeRestore -Src $d.FullName -Dst (Join-Path $Dst $d.Name)
    }
}

function Get-RelFileMap {
    # relpath -> true for every file under $Dir, keys built by the same
    # Join-Path walk the wipe below uses. Never string-prefix arithmetic:
    # enumerated FullNames can come back long-form under a short-form
    # root, which silently breaks Substring-based keys.
    param([string]$Dir, [string]$BaseRel, $Map)
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue)) {
        $fileRel = if ($BaseRel) { Join-Path $BaseRel $f.Name } else { $f.Name }
        $Map[$fileRel.ToLowerInvariant()] = $true
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)) {
        $childRel = if ($BaseRel) { Join-Path $BaseRel $d.Name } else { $d.Name }
        Get-RelFileMap -Dir $d.FullName -BaseRel $childRel -Map $Map
    }
}

function Clear-TreeForRestore {
    # Junction-aware wipe with salvage: a file created AFTER the snapshot
    # (its relative path is not in $SnapFiles) is MOVED into the salvage
    # dir instead of deleted, so a revert can never destroy data the
    # snapshot does not carry. Junctions are only ever unlinked.
    # NOTE: PowerShell variable names are case-insensitive; a local $rel
    # here would BE the $Rel parameter and accumulate across iterations.
    param([string]$Dir, [string]$Rel, $SnapFiles, [string]$SalvageDir, [ref]$Salvaged)
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue)) {
        $fileRel = if ($Rel) { Join-Path $Rel $f.Name } else { $f.Name }
        if ($SalvageDir -and -not $SnapFiles.ContainsKey($fileRel.ToLowerInvariant())) {
            $dst = Join-Path $SalvageDir $fileRel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Move-Item -LiteralPath $f.FullName -Destination $dst -Force
            $Salvaged.Value++
        } else {
            Remove-Item -LiteralPath $f.FullName -Force
        }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)) {
        if ([bool]($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            [System.IO.Directory]::Delete($d.FullName, $false)
        } else {
            $childRel = if ($Rel) { Join-Path $Rel $d.Name } else { $d.Name }
            Clear-TreeForRestore -Dir $d.FullName -Rel $childRel -SnapFiles $SnapFiles -SalvageDir $SalvageDir -Salvaged $Salvaged
            Remove-Item -LiteralPath $d.FullName -Force
        }
    }
}

function Restore-SessionsTree {
    # Put the live tree back exactly as the snapshot recorded it: wipe the
    # current children (junction-safe; anything newer than the snapshot is
    # salvaged, not deleted, when a salvage dir is given), copy the
    # snapshot back, recreate the recorded junctions. The wipe only starts
    # after the snapshot has been verified present. Returns the number of
    # salvaged files.
    param([string]$TreeBackupDir, [string]$LiveDir, [string]$SalvageDir = '')
    if (-not $LiveDir) { throw 'Restore-SessionsTree: empty live dir' }
    if (-not (Test-Path -LiteralPath $TreeBackupDir)) { throw "Tree backup missing: $TreeBackupDir" }
    $junTsv = "$TreeBackupDir.junctions.tsv"
    New-Item -ItemType Directory -Force -Path $LiveDir | Out-Null
    $snapFiles = @{}
    Get-RelFileMap -Dir $TreeBackupDir -BaseRel '' -Map $snapFiles
    $salvaged = 0
    Clear-TreeForRestore -Dir $LiveDir -Rel '' -SnapFiles $snapFiles -SalvageDir $SalvageDir -Salvaged ([ref]$salvaged)
    Copy-TreeRestore -Src $TreeBackupDir -Dst $LiveDir
    if (Test-Path -LiteralPath $junTsv) {
        foreach ($line in @(Get-Content -LiteralPath $junTsv -ErrorAction SilentlyContinue)) {
            if (-not $line) { continue }
            $parts = $line -split "`t"
            if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { continue }
            $jPath = Join-Path $LiveDir $parts[0]
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $jPath) | Out-Null
            if (Test-Path -LiteralPath $jPath) { Remove-DirectorySafe -Path $jPath }
            New-JunctionSafe -Path $jPath -Target $parts[1]
        }
    }
    return $salvaged
}

function Read-EntryMeta {
    # Regex-only field extraction from an index file. Existing entries are
    # NEVER JSON-parsed: real files exist whose enabledMcpTools map has
    # case-colliding keys that ConvertFrom-Json rejects.
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path)
    $ts = [long]0
    if ($raw -match '"lastActivityAt":(\d+)') { $ts = [long]$Matches[1] }
    $arch = $false
    if ($raw -match '"isArchived":(true|false)') { $arch = ($Matches[1] -eq 'true') }
    return @{ Ts = $ts; Arch = $arch }
}

function Get-SessionTreeState {
    # One read-only walk: which org dirs are real, which already junction to
    # _shared, which junction somewhere unexpected, and whether _shared
    # exists as a real dir.
    $realOrgs      = New-Object System.Collections.Generic.List[object]
    $oddJunctions  = New-Object System.Collections.Generic.List[string]
    $junctionCount = 0
    $accountCount  = 0
    foreach ($acct in @(Get-ChildItem -Path $SessionsDir -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($acct.Name -notmatch $script:UuidNameRe) { continue }
        if ([bool]($acct.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $oddJunctions.Add($acct.FullName); continue
        }
        $accountCount++
        foreach ($org in @(Get-ChildItem -Path $acct.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($org.Name -notmatch $script:UuidNameRe) { continue }
            if ([bool]($org.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                if (Test-JunctionTo -Path $org.FullName -Target $SharedDir) { $junctionCount++ }
                else { $oddJunctions.Add($org.FullName) }
            } else {
                $realOrgs.Add([PSCustomObject]@{ Path = $org.FullName; Account = $acct.Name; Org = $org.Name })
            }
        }
    }
    $sharedExists = $false
    $sharedIsRealDir = $false
    if (Test-Path -LiteralPath $SharedDir) {
        $sh = Get-Item -LiteralPath $SharedDir -Force
        $sharedExists = $true
        $sharedIsRealDir = -not [bool]($sh.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    }
    return [PSCustomObject]@{
        RealOrgs = $realOrgs; OddJunctions = $oddJunctions
        JunctionCount = $junctionCount; AccountCount = $accountCount
        SharedExists = $sharedExists; SharedIsRealDir = $sharedIsRealDir
    }
}

function Invoke-SessionUnify {
    # The structural pass: absorb every real <account>\<org> folder's
    # entries into _shared (newest lastActivityAt wins, archived-in-one
    # means archived-everywhere), then replace the folder with a junction.
    # Idempotent: already-junctioned orgs are not in $State.RealOrgs, and a
    # later fresh real org folder (a newcomer) takes exactly this same path.
    # The plan is computed once and then either printed (dry run) or
    # executed, so narration and writes can never disagree.
    param($State)
    Set-StrictMode -Version 2

    if ($State.SharedExists -and -not $State.SharedIsRealDir) {
        throw "_shared exists but is not a real directory, refusing to touch anything: $SharedDir"
    }

    # ---- gather candidates per filename --------------------------------
    $byName         = @{}   # fname -> List of @{Path;Ts;Arch;Mt;IsShared}
    $orgCounts      = @{}   # org path -> entry count
    $orgsWithStrays = @{}   # org path -> short description
    $copyTotal      = 0
    foreach ($org in $State.RealOrgs) {
        $entries = @(Get-ChildItem -LiteralPath $org.Path -Force -ErrorAction SilentlyContinue)
        $strays = @($entries | Where-Object { $_.PSIsContainer -or ($_.Name -notmatch $script:LocalNameRe) })
        if ($strays.Count -gt 0) {
            $orgsWithStrays[$org.Path] = (@($strays | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', ')
        }
        $n = 0
        foreach ($f in @($entries | Where-Object { (-not $_.PSIsContainer) -and ($_.Name -match $script:LocalNameRe) })) {
            $meta = Read-EntryMeta -Path $f.FullName
            $n++; $copyTotal++
            if (-not $byName.ContainsKey($f.Name)) { $byName[$f.Name] = New-Object System.Collections.Generic.List[object] }
            $byName[$f.Name].Add(@{ Path = $f.FullName; Ts = $meta.Ts; Arch = $meta.Arch
                                    Mt = [long]([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds()
                                    IsShared = $false })
        }
        $orgCounts[$org.Path] = $n
    }
    if ($State.SharedExists) {
        foreach ($f in @(Get-ChildItem -LiteralPath $SharedDir -File -Force -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match $script:LocalNameRe })) {
            $meta = Read-EntryMeta -Path $f.FullName
            if (-not $byName.ContainsKey($f.Name)) { $byName[$f.Name] = New-Object System.Collections.Generic.List[object] }
            $byName[$f.Name].Add(@{ Path = $f.FullName; Ts = $meta.Ts; Arch = $meta.Arch
                                    Mt = [long]([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds()
                                    IsShared = $true })
        }
    }

    # ---- pick winners ---------------------------------------------------
    $moves = New-Object System.Collections.Generic.List[object]
    $conflicts = 0
    $archFlips = 0
    foreach ($fname in @($byName.Keys | Sort-Object)) {
        $cands = $byName[$fname]
        $winner = $null
        $minTs = $cands[0].Ts; $maxTs = $cands[0].Ts; $archOr = $false
        foreach ($c in $cands) {
            if ($null -eq $winner) { $winner = $c }
            elseif ($c.Ts -gt $winner.Ts) { $winner = $c }
            elseif ($c.Ts -eq $winner.Ts -and $c.Mt -gt $winner.Mt) { $winner = $c }
            if ($c.Ts -lt $minTs) { $minTs = $c.Ts }
            if ($c.Ts -gt $maxTs) { $maxTs = $c.Ts }
            if ($c.Arch) { $archOr = $true }
        }
        if ($maxTs -gt $minTs) { $conflicts++ }
        $flip = ($archOr -and -not $winner.Arch)
        if ($flip) { $archFlips++ }
        if ($winner.IsShared -and -not $flip) { continue }   # already in place
        $moves.Add(@{ Fname = $fname; SrcPath = $winner.Path; Flip = $flip })
    }

    $junctionable = New-Object System.Collections.Generic.List[object]
    foreach ($org in $State.RealOrgs) {
        if (-not $orgsWithStrays.ContainsKey($org.Path)) { $junctionable.Add($org) }
    }

    # ---- dry run: narrate the plan --------------------------------------
    if ($DryRun) {
        Write-Host "Restructure plan for $($SessionsDir):"
        if (-not $State.SharedExists) { Write-Host "  would create the shared index dir: $SharedDir" }
        Write-Host ('  would place {0} unique session entries into _shared ({1} per-org copies collapse into them; {2} had diverging copies, resolved by newest activity; {3} archive flags propagated)' -f `
            $byName.Count, $copyTotal, $conflicts, $archFlips)
        foreach ($org in $junctionable) {
            Write-Host ('  would replace {0}\{1} ({2} entries) with a junction -> _shared' -f $org.Account, $org.Org, $orgCounts[$org.Path])
        }
        foreach ($orgPath in @($orgsWithStrays.Keys | Sort-Object)) {
            Write-Host ('  would LEAVE REAL (unexpected content: {0}): {1}' -f $orgsWithStrays[$orgPath], $orgPath)
        }
        Write-Host '  the whole tree would be backed up first (claude-sync -Revert restores it)'
        return
    }

    # ---- execute --------------------------------------------------------
    if (Test-ClaudeDesktopRunning) {
        throw 'Claude Desktop is running; refusing to restructure the sessions tree.'
    }
    Write-Log ("Restructuring sessions index: {0} entries -> _shared, {1} org folder(s) to junction..." -f $byName.Count, $junctionable.Count)
    Backup-SessionsTree
    try {
        if (-not (Test-Path -LiteralPath $SharedDir)) {
            New-Item -ItemType Directory -Force -Path $SharedDir | Out-Null
        }
        foreach ($mv in $moves) {
            $dst = Join-Path $SharedDir $mv.Fname
            if ($mv.Flip) {
                $raw = [System.IO.File]::ReadAllText($mv.SrcPath)
                [System.IO.File]::WriteAllText($dst, $raw.Replace('"isArchived":false', '"isArchived":true'))
                (Get-Item -LiteralPath $dst).LastWriteTimeUtc = (Get-Item -LiteralPath $mv.SrcPath).LastWriteTimeUtc
            } else {
                [System.IO.File]::Copy($mv.SrcPath, $dst, $true)
            }
        }
        foreach ($org in $junctionable) {
            # Belt and suspenders: nothing may be lost by the removal.
            foreach ($f in @(Get-ChildItem -LiteralPath $org.Path -File -Force -ErrorAction SilentlyContinue)) {
                if (-not (Test-Path -LiteralPath (Join-Path $SharedDir $f.Name))) {
                    throw "entry was not absorbed into _shared: $($f.FullName)"
                }
            }
            Remove-DirectorySafe -Path $org.Path
            New-JunctionSafe -Path $org.Path -Target $SharedDir
        }
        # Seed the heal ledger: every id visible now, plus every id the old
        # v3 ledger ever saw fully synced. An id whose entry is absent from
        # the union but present in the v3 ledger was deleted by the user
        # after its last full sync -- seeding it keeps self-heal from
        # resurrecting it out of its transcript.
        $ids = Get-HealLedger
        foreach ($fname in @($byName.Keys)) {
            if ($fname -match $script:LocalNameRe) { $ids[$Matches[1].ToLowerInvariant()] = $true }
        }
        if (Test-Path -LiteralPath $LedgerPath) {
            foreach ($line in @(Get-Content -LiteralPath $LedgerPath -ErrorAction SilentlyContinue)) {
                if ($line -and $line -match '^local_([0-9a-fA-F-]{36})\.json\t') {
                    $ids[$Matches[1].ToLowerInvariant()] = $true
                }
            }
        }
        Save-HealLedger -Ids $ids
    } catch {
        Write-Log ("RESTRUCTURE FAILED: {0}" -f $_)
        Write-Log "Restoring the pre-run tree from this run's backup..."
        $null = Restore-SessionsTree -TreeBackupDir (Join-Path $script:RunDir 'sessions-tree') -LiveDir $SessionsDir
        Write-Log 'Restored. The sessions tree is back to its pre-run state.'
        throw
    }
    Write-Log ('Unified: {0} session entries in _shared; {1} org folder(s) junctioned ({2} diverging copies resolved by newest activity, {3} archive flags propagated).' -f `
        $byName.Count, $junctionable.Count, $conflicts, $archFlips)
    foreach ($orgPath in @($orgsWithStrays.Keys | Sort-Object)) {
        Write-Log ('  left REAL, unexpected content ({0}): {1}' -f $orgsWithStrays[$orgPath], $orgPath)
    }
}

# ---------- self-heal: rebuild missing entries from transcripts ------------
function ConvertTo-EpochMs {
    param([string]$Iso)
    try {
        return [long]([DateTimeOffset]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUnixTimeMilliseconds()
    } catch { return [long]0 }
}

function ConvertFrom-JsonEscapedString {
    # $S is the inside of a well-formed JSON string literal (captured by
    # regex); wrapping it back into a tiny JSON doc is the safest unescape.
    param([string]$S)
    try { return (ConvertFrom-Json ('{"v":"' + $S + '"}')).v } catch { return $S }
}

function Read-FileTailText {
    # Last chunk of a (possibly live, possibly huge) file, opened with a
    # ReadWrite share so an open transcript never fails the scan. A partial
    # first multibyte char decodes as garbage and is harmless: only complete
    # matches later in the chunk are used.
    param([string]$Path, [int]$MaxBytes = 65536)
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($len -le 0) { return '' }
        $take = [int]([Math]::Min([long]$MaxBytes, $len))
        $fs.Seek(-$take, [System.IO.SeekOrigin]::End) | Out-Null
        $buf = New-Object byte[] $take
        $read = $fs.Read($buf, 0, $take)
        return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } finally { $fs.Close() }
}

function Read-TranscriptMeta {
    # Streaming metadata extraction from a transcript: head lines give the
    # custom title / first user message, cwd, first timestamp and model;
    # the tail chunk gives the last timestamp (and any late rename). The
    # transcript is only ever read, line by line, never loaded whole.
    param([string]$Path)
    $title = $null; $titleSource = 'auto'; $summaryTitle = $null
    $cwd = $null; $createdIso = $null; $model = $null
    $isSidechain = $false

    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $reader = New-Object System.IO.StreamReader($fs)
    try {
        $lineNo = 0
        $sawMessageEntry = $false
        while (-not $reader.EndOfStream -and $lineNo -lt 250) {
            $line = $reader.ReadLine()
            $lineNo++
            if (-not $line) { continue }
            if ($line.StartsWith('{"type":"custom-title"') -and $line -match '"customTitle":"((?:[^"\\]|\\.)*)"') {
                $t = ConvertFrom-JsonEscapedString $Matches[1]
                $t = ($t -replace '\s+', ' ').Trim()
                if ($t) { $title = $t; $titleSource = 'custom' }
            }
            if ((-not $summaryTitle) -and $line.StartsWith('{"type":"summary"') -and $line -match '"summary":"((?:[^"\\]|\\.)*)"') {
                $summaryTitle = ConvertFrom-JsonEscapedString $Matches[1]
            }
            if ((-not $createdIso) -and $line -match '"timestamp":"([0-9TZ:.+-]{10,40})"') { $createdIso = $Matches[1] }
            if ((-not $cwd) -and $line -match '"cwd":"((?:[^"\\]|\\.)*)"') {
                $cwd = ConvertFrom-JsonEscapedString $Matches[1]
            }
            if ((-not $model) -and $line -match '"model":"(claude-[A-Za-z0-9.\[\]_-]{1,60})"') { $model = $Matches[1] }
            if ($line.StartsWith('{"parentUuid"')) {
                if (-not $sawMessageEntry) {
                    $sawMessageEntry = $true
                    # Only the file's own first message entry decides
                    # sidechain-ness; quoted content later can't.
                    if ($line.Contains('"isSidechain":true')) { $isSidechain = $true; break }
                }
                if (($titleSource -ne 'custom') -and (-not $title) -and $line.Contains('"type":"user"') -and
                    (-not $line.Contains('"isMeta":true')) -and (-not $line.Contains('"type":"tool_result"'))) {
                    $cand = $null
                    if ($line -match '"role":"user","content":"((?:[^"\\]|\\.)*)"') {
                        $cand = ConvertFrom-JsonEscapedString $Matches[1]
                    } elseif ($line -match '"type":"text","text":"((?:[^"\\]|\\.)*)"') {
                        $cand = ConvertFrom-JsonEscapedString $Matches[1]
                    }
                    if ($cand) {
                        $cand = ($cand -replace '\s+', ' ').Trim()
                        $bad = ($cand -eq '') -or $cand.StartsWith('Caveat:') -or $cand.StartsWith('<command-') -or
                               $cand.StartsWith('<local-command') -or $cand.StartsWith('[Request interrupted') -or
                               $cand.StartsWith('<system')
                        if (-not $bad) {
                            if ($cand.Length -gt 60) { $cand = $cand.Substring(0, 60).TrimEnd() }
                            $title = $cand
                        }
                    }
                }
            }
            if ($title -and ($titleSource -eq 'custom') -and $cwd -and $createdIso -and $model) { break }
        }
    } finally { $reader.Close() }

    if ((-not $title) -and $summaryTitle) {
        $t = ($summaryTitle -replace '\s+', ' ').Trim()
        if ($t) {
            if ($t.Length -gt 60) { $t = $t.Substring(0, 60).TrimEnd() }
            $title = $t
        }
    }

    $lastIso = $null
    if (-not $isSidechain) {
        $tailText = Read-FileTailText -Path $Path
        $mts = [regex]::Matches($tailText, '"timestamp":"([0-9TZ:.+-]{10,40})"')
        if ($mts.Count -gt 0) { $lastIso = $mts[$mts.Count - 1].Groups[1].Value }
        $cts = [regex]::Matches($tailText, '"customTitle":"((?:[^"\\]|\\.)*)"')
        if ($cts.Count -gt 0) {
            $t = ConvertFrom-JsonEscapedString $cts[$cts.Count - 1].Groups[1].Value
            $t = ($t -replace '\s+', ' ').Trim()
            if ($t) {
                if ($t.Length -gt 60) { $t = $t.Substring(0, 60).TrimEnd() }
                $title = $t; $titleSource = 'custom'
            }
        }
    }

    $item = Get-Item -LiteralPath $Path
    $createdMs = [long]0
    if ($createdIso) { $createdMs = ConvertTo-EpochMs $createdIso }
    if ($createdMs -le 0) { $createdMs = [long]([DateTimeOffset]$item.CreationTimeUtc).ToUnixTimeMilliseconds() }
    $lastMs = [long]0
    if ($lastIso) { $lastMs = ConvertTo-EpochMs $lastIso }
    if ($lastMs -le 0) { $lastMs = [long]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeMilliseconds() }
    if ($lastMs -lt $createdMs) { $lastMs = $createdMs }
    if (-not $cwd) { $cwd = [string]$HOME }
    if (-not $model) { $model = 'claude-opus-4-8' }
    return @{ Title = $title; TitleSource = $titleSource; Cwd = $cwd
              CreatedMs = $createdMs; LastMs = $lastMs; Model = $model; IsSidechain = $isSidechain }
}

function Get-HealLedger {
    # Every session id self-heal has ever seen listed (or generated). An id
    # here whose entry is gone was deleted by the user in the app; without
    # this file every deletion would be resurrected from its transcript on
    # the next run.
    $ids = @{}
    if (-not (Test-Path -LiteralPath $HealLedgerPath)) { return $ids }
    foreach ($line in @(Get-Content -LiteralPath $HealLedgerPath -ErrorAction SilentlyContinue)) {
        if ($line -and $line -match $script:UuidNameRe) { $ids[$line.ToLowerInvariant()] = $true }
    }
    return $ids
}

function Save-HealLedger {
    # Atomic (temp + move), backed into the run manifest, and skipped
    # entirely when nothing changed so idle runs stay write-free.
    param($Ids)
    $lines = @($Ids.Keys | Sort-Object)
    $new = ''
    if ($lines.Count -gt 0) { $new = (($lines -join "`n") + "`n") }
    $old = ''
    if (Test-Path -LiteralPath $HealLedgerPath) { $old = [System.IO.File]::ReadAllText($HealLedgerPath) }
    if ($new -eq $old) { return }
    New-Item -ItemType Directory -Force -Path $CanonicalDir | Out-Null
    Initialize-RunDir
    if ($old -ne '') {
        $bak = Join-Path $script:RunDir 'heal-ledger.tsv.pre'
        if (-not (Test-Path -LiteralPath $bak)) {
            [System.IO.File]::WriteAllText($bak, $old)
            Add-ManifestRow ("overwrote`t{0}`t{1}" -f $HealLedgerPath, $bak)
        }
    } else {
        Add-ManifestRow ("created`t{0}" -f $HealLedgerPath)
    }
    $tmp = "$HealLedgerPath.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $new)
    Move-Item -LiteralPath $tmp -Destination $HealLedgerPath -Force
}

function Invoke-SessionHeal {
    # For every transcript with no list entry in _shared and no heal-ledger
    # record, generate a minimal entry the app can render and resume.
    # Additive only: existing entries are never edited or deleted, and
    # transcripts are never touched. Safe with Claude open (the app reads
    # the index at launch). $ListedOverride lets a pre-restructure dry run
    # preview the heal against the ids the restructure WOULD leave listed.
    param([hashtable]$ListedOverride = $null)
    Set-StrictMode -Version 2
    if (($null -eq $ListedOverride) -and -not (Test-Path -LiteralPath $SharedDir)) { return }
    $listed = @{}
    if ($null -ne $ListedOverride) {
        $listed = $ListedOverride
    } else {
        foreach ($f in @(Get-ChildItem -LiteralPath $SharedDir -File -Force -ErrorAction SilentlyContinue)) {
            if ($f.Name -match $script:LocalNameRe) { $listed[$Matches[1].ToLowerInvariant()] = $true }
        }
    }
    if (-not (Test-Path -LiteralPath $ProjectsDir)) {
        Out-Sync "Self-heal: transcripts dir not found ($ProjectsDir), nothing to scan."
        return
    }
    $seen = Get-HealLedger
    # Ids the v3 ledger saw fully synced are tombstones forever: an id
    # there with no entry now was deleted by the user post-sync. Merging
    # here (not only at unify time) keeps dry runs and real runs agreeing.
    if (Test-Path -LiteralPath $LedgerPath) {
        foreach ($line in @(Get-Content -LiteralPath $LedgerPath -ErrorAction SilentlyContinue)) {
            if ($line -and $line -match '^local_([0-9a-fA-F-]{36})\.json\t') {
                $seen[$Matches[1].ToLowerInvariant()] = $true
            }
        }
    }
    $plan = New-Object System.Collections.Generic.List[object]
    $scanned = 0; $skipSeen = 0; $skipEmpty = 0; $skipSide = 0; $skipNoTitle = 0
    foreach ($projDir in @(Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue)) {
        foreach ($f in @(Get-ChildItem -Path $projDir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
            if ($f.BaseName -notmatch $script:UuidNameRe) { continue }
            $scanned++
            $id = $f.BaseName.ToLowerInvariant()
            if ($listed.ContainsKey($id)) { continue }
            if ($seen.ContainsKey($id)) { $skipSeen++; continue }
            if ($f.Length -eq 0) { $skipEmpty++; continue }
            $tm = Read-TranscriptMeta -Path $f.FullName
            if ($tm.IsSidechain) { $skipSide++; continue }
            if (-not $tm.Title) { $skipNoTitle++; continue }
            $plan.Add(@{ Id = $f.BaseName; Meta = $tm })
        }
    }

    if ($DryRun) {
        if ($plan.Count -eq 0) {
            Write-Host ('Self-heal: nothing to generate ({0} transcripts scanned).' -f $scanned)
        } else {
            Write-Host ('Self-heal: would generate {0} missing list entries from transcripts:' -f $plan.Count)
            foreach ($p in $plan) { Write-Host ('  would create: local_{0}.json  [{1}]' -f $p.Id, $p.Meta.Title) }
        }
        return
    }

    $made = 0
    foreach ($p in $plan) {
        $m = $p.Meta
        $dst = Join-Path $SharedDir ('local_{0}.json' -f $p.Id)
        if (Test-Path -LiteralPath $dst) { continue }
        $obj = [ordered]@{
            sessionId       = ('local_{0}' -f $p.Id)
            cliSessionId    = $p.Id
            cwd             = $m.Cwd
            originCwd       = $m.Cwd
            lastFocusedAt   = [long]$m.LastMs
            createdAt       = [long]$m.CreatedMs
            lastActivityAt  = [long]$m.LastMs
            model           = $m.Model
            effort          = 'high'
            isArchived      = $false
            title           = $m.Title
            titleSource     = $m.TitleSource
            permissionMode  = 'bypassPermissions'
            enabledMcpTools = @{}
        }
        $json = ConvertTo-Json -InputObject $obj -Compress -Depth 8
        Initialize-RunDir
        [System.IO.File]::WriteAllText($dst, $json)
        try {
            (Get-Item -LiteralPath $dst).LastWriteTimeUtc = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$m.LastMs).UtcDateTime
        } catch { }
        Add-ManifestRow ("created`t{0}" -f $dst)
        $listed[$p.Id.ToLowerInvariant()] = $true
        $made++
        Write-Log ('  generated from transcript: local_{0}.json  [{1}]' -f $p.Id, $m.Title)
    }

    # Every id listed right now becomes 'seen': if the user later deletes
    # its entry in the app, self-heal will never bring it back.
    $changed = $false
    foreach ($id in @($listed.Keys)) {
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $changed = $true }
    }
    if ($changed) { Save-HealLedger -Ids $seen }

    if ($made -gt 0) {
        Write-Log ('Self-heal: generated {0} entries ({1} transcripts scanned; skipped {2} seen-before, {3} sidechain, {4} empty, {5} with no usable first message).' -f `
            $made, $scanned, $skipSeen, $skipSide, $skipEmpty, $skipNoTitle)
    } else {
        Out-Sync ('Self-heal: nothing to generate ({0} transcripts scanned).' -f $scanned)
    }
}

function Invoke-SessionModule {
    # Session work for one run: restructure when needed and possible
    # (Claude fully closed), then self-heal. The restructure is never
    # attempted under a live app: writing into a tree the app has open
    # is externally silent but can be overwritten or half-read.
    Set-StrictMode -Version 2
    if (-not (Test-Path $SessionsDir)) {
        Out-Sync "Sessions folder not found: $SessionsDir"
        Out-Sync 'Open Claude Desktop, go to Claude Code, and start one session first.'
        return 1
    }
    $state = Get-SessionTreeState
    foreach ($odd in $state.OddJunctions) {
        Out-Sync "  NOTE: junction to an unexpected target, left alone: $odd"
    }
    $needsStructure = (($state.RealOrgs.Count -gt 0) -or (-not $state.SharedExists))
    if ($needsStructure) {
        if ($DryRun) {
            Invoke-SessionUnify -State $state
            # Preview the heal too, against the ids the restructure would
            # leave listed, so the dry run shows the WHOLE first real run.
            $wouldList = @{}
            foreach ($org in $state.RealOrgs) {
                foreach ($f in @(Get-ChildItem -Path $org.Path -Filter 'local_*.json' -File -ErrorAction SilentlyContinue)) {
                    if ($f.Name -match $script:LocalNameRe) { $wouldList[$Matches[1].ToLowerInvariant()] = $true }
                }
            }
            if ($state.SharedExists) {
                foreach ($f in @(Get-ChildItem -LiteralPath $SharedDir -Filter 'local_*.json' -File -ErrorAction SilentlyContinue)) {
                    if ($f.Name -match $script:LocalNameRe) { $wouldList[$Matches[1].ToLowerInvariant()] = $true }
                }
            }
            Invoke-SessionHeal -ListedOverride $wouldList
            return 0
        } elseif (Test-ClaudeDesktopRunning) {
            Out-Sync ('Claude Desktop is running: the restructure ({0} org folder(s) -> _shared junctions) is postponed. Close Claude Desktop fully and run claude-sync again.' -f $state.RealOrgs.Count)
        } else {
            Invoke-SessionUnify -State $state
            $state = Get-SessionTreeState
        }
    }
    if ($state.SharedExists) {
        Invoke-SessionHeal
        $n = @(Get-ChildItem -LiteralPath $SharedDir -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
        Out-Sync ('Sessions: one unified index, {0} entries in _shared, visible to every account and org.' -f $n)
    } else {
        Out-Sync 'Self-heal skipped: no _shared index yet (it runs after the restructure).'
    }
    return 0
}

# ---------- sync entry point ------------------------------------------------
function Invoke-Sync {
    $doDeletes = -not $NoDeletes

    # Profile customization first: fast, and independent of the session
    # machinery (profiles exist even with a single account or no sessions).
    Sync-Profiles -Deletes $doDeletes

    $rc = Invoke-SessionModule
    if ($DryRun) {
        Write-Host 'Nothing was written.'
        return $rc
    }
    if ($rc -ne 0) { return $rc }

    # Prune old backup runs (keep the newest N, reverted ones included).
    # Run dirs contain only real copies (junctions are recorded as tsv
    # rows, never materialized), so a recursive delete here is safe.
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

    if ($script:RunDir) {
        Write-Log "Sync complete. Backup: $($script:RunDir) (claude-sync -Revert undoes this run)"
    } else {
        Write-Log 'Sync complete. Nothing needed changing.'
    }
    return $rc
}

# ---------- revert ---------------------------------------------------------
function Invoke-Revert {
    # Undo the most recent sync run: replay its manifest in REVERSE order
    # (later writes undo first, which is what makes the structural rows
    # compose with file rows), then mark the backup dir .reverted so a
    # second -Revert targets the run before it. A run that restructured the
    # tree ('tree' row) restores the whole pre-run tree, junction-aware,
    # and -- like the restructure itself -- only with Claude fully closed.
    Set-StrictMode -Version 2
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
    $lines = @(Get-Content -LiteralPath $manifestPath)

    $hasTree = $false
    foreach ($line in $lines) {
        if ($line -and ($line -split "`t")[0] -eq 'tree') { $hasTree = $true; break }
    }
    if ($hasTree -and (Test-ClaudeDesktopRunning)) {
        Write-Host 'This revert restores the sessions tree structure and must run with Claude Desktop fully closed. Close Claude and run -Revert again.'
        return 1
    }

    Write-Log "Reverting sync run $($run.Name)..."
    $removed = 0; $restored = 0; $undeleted = 0; $trees = 0
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
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
            'tree' {
                $salvageDir = Join-Path $run.FullName 'revert-salvage'
                $salvaged = Restore-SessionsTree -TreeBackupDir $parts[2] -LiveDir $parts[1] -SalvageDir $salvageDir
                if ($salvaged -gt 0) {
                    Write-Log ("  {0} file(s) newer than this run's snapshot were moved aside to {1} (nothing deleted)." -f $salvaged, $salvageDir)
                }
                $trees++
            }
        }
    }
    Rename-Item -LiteralPath $run.FullName -NewName ($run.Name + '.reverted')
    $msg = "Reverted: removed $removed created file(s), restored $restored overwritten file(s), restored $undeleted deleted file(s)."
    if ($trees -gt 0) { $msg += " Restored the full pre-run sessions tree ($trees snapshot(s), junctions included)." }
    Write-Log $msg
    Write-Log "Backup kept at $($run.Name).reverted. Run -Revert again to undo the previous run."
    return 0
}

# ---------- watcher (hands-off mode) ---------------------------------------
function Invoke-Watch {
    # Purely event-driven: a FileSystemWatcher on the transcripts dir wakes
    # the loop the moment any *.jsonl is created or appended (a conversation
    # exists the instant its transcript does, before the reply even lands).
    # Trailing debounce: sync fires after QUIET seconds of write silence, at
    # most once per MININT seconds. Quit needs no trigger of its own: a
    # quitting app's final writes are themselves events. Self-heal is
    # additive and safe with instances open; the restructure part
    # self-postpones while any instance runs.
    $QUIET = 8; $MININT = 45
    New-Item -ItemType Directory -Force -Path $ProjectsDir | Out-Null
    $fsw = New-Object System.IO.FileSystemWatcher $ProjectsDir, '*.jsonl'
    $fsw.IncludeSubdirectories = $true
    $fsw.InternalBufferSize = 65536
    Register-ObjectEvent $fsw Created -SourceIdentifier 'claude-sync-fs-created' | Out-Null
    Register-ObjectEvent $fsw Changed -SourceIdentifier 'claude-sync-fs-changed' | Out-Null
    $fsw.EnableRaisingEvents = $true
    Write-Log '[watcher] Watcher started (transcript events).'
    $lastRun = Get-Date
    $lastEventAt = $null
    while ($true) {
        # Wait-Event doubles as the sleep: returns on the first event,
        # times out quietly otherwise.
        $ev = Wait-Event -Timeout 3 -ErrorAction SilentlyContinue
        if ($ev) {
            $lastEventAt = Get-Date
            Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
            Get-Event -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
            continue
        }
        if (-not $lastEventAt) { continue }
        $now = Get-Date
        if ((($now - $lastEventAt).TotalSeconds) -lt $QUIET) { continue }
        if ((($now - $lastRun).TotalSeconds) -lt $MININT) { continue }
        Write-Log '[watcher] Transcript activity: running sync...'
        # Fresh run state per iteration (one backup run dir per sync).
        $script:RunDir = $null
        $script:ManifestPath = $null
        try { Invoke-Sync | Out-Null } catch { Write-Log ('[watcher] sync failed: {0}' -f $_.Exception.Message) }
        $lastRun = Get-Date
        $lastEventAt = $null
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
    Write-Host "  Remove-Item `"$CanonicalPath`", `"$LogPath`", `"$LedgerPath`", `"$LedgerAccountsPath`", `"$McpLedgerPath`", `"$HealLedgerPath`"; Remove-Item -Recurse `"$BackupsDir`""
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
    $state = Get-SessionTreeState
    if ($state.SharedExists) {
        $n = @(Get-ChildItem -LiteralPath $SharedDir -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
        Write-Host ('  unified: {0} session entries in _shared; {1} org junction(s) across {2} account(s)' -f `
            $n, $state.JunctionCount, $state.AccountCount)
    }
    if ($state.RealOrgs.Count -gt 0) {
        Write-Host ('  pending restructure: {0} real org folder(s); run claude-sync with Claude Desktop closed' -f $state.RealOrgs.Count)
        foreach ($org in $state.RealOrgs) {
            $n = @(Get-ChildItem -Path $org.Path -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
            Write-Host ('    {0}\{1}: {2} entries' -f $org.Account, $org.Org, $n)
        }
    }
    foreach ($odd in $state.OddJunctions) {
        Write-Host "  junction to an unexpected target (left alone): $odd"
    }
    $healN = (Get-HealLedger).Count
    if ($healN -gt 0) { Write-Host ('  heal ledger: {0} session id(s) tracked' -f $healN) }
    if (Test-Path -LiteralPath $ProjectsDir) {
        $tn = 0
        foreach ($pd in @(Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue)) {
            $tn += @(Get-ChildItem -Path $pd.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue).Count
        }
        Write-Host ('  transcripts on disk: {0}' -f $tn)
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
        # 'Sync complete' is the completion line since v3; 'Done.' covers
        # logs from the v1/v2 scripts so history stays readable.
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
One shared Claude Code session list for every Claude Desktop account and
org on this PC, plus customization sync (MCP servers, preferences,
Desktop Extensions) across claude-deck profiles.

Sessions work structurally since v4 (Windows): a one-time restructure
(needs Claude fully closed) moves the union of every <account>\<org>
index into claude-code-sessions\_shared and replaces the org folders
with directory junctions to it. After that there is one physical list:
new sessions appear under every account instantly, a delete in the app
is a delete everywhere, nothing is copied on a schedule. Every run also
self-heals: a session whose transcript exists but whose list entry was
never written (app restart, rewound session) gets a minimal entry
generated from the transcript. Existing entries are never edited;
transcripts are never touched; deletes are never resurrected (tracked
in heal-ledger.tsv). The restructure backs up the whole tree first and
-Revert restores it completely (also only with Claude closed).

Usage: claude-sync [command]   (--gnu-style spellings work too)

  (no command)     Run the sync. With Claude closed: restructure (first
                   run), then self-heal. With Claude open: self-heal only;
                   the restructure waits and says so.
  -DryRun          Show everything a run would do, write nothing.
  -NoDeletes       MCP servers only: skip removal propagation (and thereby
                   restore a server deleted on one side). Sessions no
                   longer need it: one physical list has no copies to
                   reconcile.
  -Revert          Undo the most recent run from its backup. A run that
                   restructured the tree restores it fully (Claude must
                   be closed for that).
  -Status          Show tree state, entry counts, install state.
  -Install         Copy this script to ~\.claude\scripts\ and register the
                   'claude-sync' command in your PowerShell profile.
                   Re-run to update.
  -Uninstall       Remove the command and the auto-sync task (if enabled).
  -AutoInstall     Auto-sync every time Claude Desktop quits (per-user
                   Scheduled Task, no admin rights).
  -AutoUninstall   Disable auto-sync.
  -Version         Print version.
  -Help            This text.

First run: close Claude Desktop fully, run claude-sync once, reopen.
Everything after that can run anytime (self-heal is safe with the app
open; structural changes simply wait for a closed app).
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
