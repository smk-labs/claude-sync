# claude-sync

**See all your Claude Code sessions, no matter which Claude account you're logged into.** Claude Desktop keeps a separate session index per account, so switching accounts makes your local session list look empty even though every transcript is still on disk. `claude-sync` keeps those indexes in sync across accounts: install once with one command, then just run `claude-sync` (or let auto-sync do it for you).

Works on **macOS** and **Windows**. No dependencies, one script per platform.

---

> This is a small vibe-coded utility that copies files inside your own home folder. It can't break Claude (it never touches the app itself), but as always: read the script before you run it.

---

## Install & update

Same one-liner does both, fresh install or pulling the latest version. From then on, the `claude-sync` command works in every new terminal.

**macOS:**

```bash
curl -fsSLo /tmp/cs.sh https://raw.githubusercontent.com/smk-labs/claude-sync/main/claude-sync.sh && chmod +x /tmp/cs.sh && /tmp/cs.sh --install && source ~/.zshrc
```

**Windows (PowerShell):**

```powershell
iwr -useb https://raw.githubusercontent.com/smk-labs/claude-sync/main/claude-sync.ps1 -OutFile "$env:TEMP\claude-sync.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\claude-sync.ps1" -Install; . $PROFILE
```

Then:

```bash
claude-sync
```

That's it.

---

## What's new in v2

v1 only copied session entries that were *missing* in other accounts. v2 does a real sync:

- **Sessions update everywhere, not just appear.** Continue or rename a session in one account and every other account gets the newer version. Newest activity wins.
- **Archiving propagates.** Archive a session in one account and the next sync archives it in all accounts.
- **Honest summary numbers.** The report counts sessions, not file copies. "3 new, 5 updated" means 3 sessions and 5 sessions, not the 36 files behind them.
- **Much faster.** One single pass over all files instead of comparing every account against every other one.
- **Safe by default.** Every file a sync changes is backed up first, and `claude-sync --revert` undoes the last sync completely.
- **Preview first.** `claude-sync --dry-run` prints everything a sync would do, without writing a single file.
- **v2.1 adds opt-in delete syncing.** Turn it on with `--sync-deletes` when you want deletes to propagate too. See [Syncing deletes (opt-in)](#syncing-deletes-opt-in) below.

### Two honest limitations

1. **By default, deleting a session in one account does not delete it elsewhere.** After the next sync, the deleted session comes back (the other accounts still have it). This is deliberate: guessing whether a missing file means "deleted on purpose" is too risky, so sync never deletes anything unless you ask it to. See [Syncing deletes (opt-in)](#syncing-deletes-opt-in) to turn this on.
2. **Un-archiving does not propagate.** If a session is still archived in *any* account, the next sync archives it everywhere again. To truly unarchive a session, unarchive it in every account (or unarchive it and don't sync).

---

## Syncing deletes (opt-in)

By default, `claude-sync` never deletes anything. It's off because guessing whether a missing session means "deleted on purpose" or "not synced yet" is risky, and getting it wrong loses a conversation. If that default is too cautious for you, turn on delete syncing yourself.

Recommended flow: preview first, then run for real.

```bash
claude-sync --dry-run --sync-deletes   # preview what would be deleted
claude-sync --sync-deletes             # actually delete
```

**How it decides.** `claude-sync` keeps a ledger that remembers which sessions were fully synced across every account. If a session that used to be in an account is now missing from it, that counts as a delete, unless some other copy of that session shows activity newer than the last full sync. In that case the session was used after the last sync, so it's kept instead (normal resurrection applies), not deleted.

Deletions are backed up first, just like every other change `claude-sync` makes. `claude-sync --revert` brings deleted sessions back, the same way it undoes any other sync.

Auto-sync (the hands-off watcher) never deletes, even if you've turned on `--sync-deletes` for manual runs. Delete propagation only ever happens when you run it yourself.

---

## The problem

You log into a second account in Claude Desktop and your Claude Code session list is suddenly empty. Your sessions are not gone:

- **Transcripts** live in `~/.claude/projects` and are shared by every account.
- **The session index** (what the desktop app's session list shows) is per account: `~/Library/Application Support/Claude/claude-code-sessions/<account-uuid>/<org-uuid>/local_*.json` on macOS, `%APPDATA%\Claude\claude-code-sessions\...` on Windows.

`claude-sync` merges those per-account indexes. After a restart of Claude, every account sees the same full, up-to-date list.

---

## Before your first sync (important)

`claude-sync` can only see accounts that already have a session folder, and a freshly added account doesn't have one yet. So, once per new account:

1. **Log in** to the new account in Claude Desktop.
2. Open **Claude Code** and start one **throwaway session**. A plain "hi" is enough. This makes Claude create the session folder for that account, so `claude-sync` can recognize it.
3. **Quit** Claude Desktop.
4. Run `claude-sync`.
5. Reopen Claude. The full session list is there under the new account.

---

## Commands

| macOS | Windows | What it does |
|---|---|---|
| `claude-sync` | `claude-sync` | Run the sync. Idempotent, safe to re-run anytime. |
| `claude-sync --dry-run` | `claude-sync -DryRun` | Show everything a sync would create or overwrite. Writes nothing, not even backups. |
| `claude-sync --sync-deletes` | `claude-sync -SyncDeletes` | Also propagate deletes (see [Syncing deletes (opt-in)](#syncing-deletes-opt-in)). Can combine with `--dry-run` / `-DryRun` to preview deletes first. |
| `claude-sync --revert` | `claude-sync -Revert` | Undo the last sync: delete the files it created, restore the files it overwrote (including sessions deleted by `--sync-deletes`). Run again to undo the sync before that. |
| `claude-sync --status` | `claude-sync -Status` | Show detected accounts, per-account session counts, install state, last sync time, stored backup runs. |
| `claude-sync --install` | `claude-sync -Install` | Copy the script to `~/.claude/scripts/` and register the `claude-sync` command (zshrc alias / PowerShell profile function). Re-run to update. |
| `claude-sync --uninstall` | `claude-sync -Uninstall` | Remove the registered command (and the auto-sync watcher). |
| `claude-sync --auto-install` | `claude-sync -AutoInstall` | Hands-off mode: auto-sync every time Claude Desktop quits. |
| `claude-sync --auto-uninstall` | `claude-sync -AutoUninstall` | Disable hands-off mode. |
| `claude-sync --version` | `claude-sync -Version` | Print the version. |
| `claude-sync --help` | `claude-sync -Help` | Print usage. |

---

## Hands-off mode (optional)

Don't want to remember to run `claude-sync` after switching accounts? One command wires up a watcher that syncs automatically after Claude Desktop quits:

```bash
claude-sync --auto-install      # enable
claude-sync --auto-uninstall    # disable
```

On macOS this is a LaunchAgent (a small bash loop that checks every few seconds, plus a plist in `~/Library/LaunchAgents/`), on Windows a Scheduled Task. No sudo, no admin rights, no system changes. Log at `~/.claude/scripts/claude-sync.log`.

---

## How it works

1. **Inventory.** Lists every `local_*.json` session index file under every account folder in Claude's `claude-code-sessions` data dir, and reads two fields from each: last activity time and archived state.
2. **Pick winners.** For each session, the copy with the newest activity wins. If the session is archived in any account, the winning copy is marked archived too.
3. **Distribute.** Every account gets the winning copy of every session: missing files are created, older files are backed up and overwritten, up-to-date files are skipped.

The desktop app picks up the changes on next launch. The transcripts the index points to are already on disk, shared in `~/.claude/projects`, and are never touched.

---

## Safety

- **Backups before every write.** Each sync that changes anything stores the old files under `~/.claude/scripts/backups/`, with a manifest of exactly what was created and what was overwritten. The 10 most recent runs are kept.
- **One-command undo.** `claude-sync --revert` replays the newest manifest in reverse. Run it again to step back one more sync.
- **Never deletes by default.** Sync only creates and updates index files unless you opt in with `--sync-deletes` (see [Syncing deletes (opt-in)](#syncing-deletes-opt-in)).
- **Preview mode.** `claude-sync --dry-run` prints every planned action and the summary, and writes nothing.
- **Index only.** Your actual session transcripts in `~/.claude/projects` are never touched.
- **Only account folders are touched.** Anything else in the sessions dir (for example a `_shared` folder left by other sync tools or experiments) is skipped and never written into.
- **Sentinel-wrapped shell edits.** The command registration lives between `# >>> claude-sync shortcut >>>` markers in your zshrc / PowerShell profile, and uninstall removes exactly that block (with a timestamped backup first).

---

## Won't Claude fix this itself?

Maybe someday. As of mid 2026, Claude Desktop keeps the local Claude Code session list strictly per account and doesn't merge it when you switch. Until that changes, `claude-sync` bridges the gap. The day it's obsolete, removal is one command (see below).

---

## Uninstall fully

**macOS:**

```bash
claude-sync --uninstall        # removes the alias and the auto-sync agent
rm -rf ~/.claude/scripts/claude-sync.sh ~/.claude/scripts/claude-sync.log ~/.claude/scripts/backups
```

**Windows:**

```powershell
claude-sync -Uninstall
Remove-Item -Recurse "$HOME\.claude\scripts\claude-sync.ps1", "$HOME\.claude\scripts\claude-sync.log", "$HOME\.claude\scripts\backups"
```

---

## Troubleshooting

**"Only one account folder found. Nothing to sync."**
The other account has never created a Claude Code session on this machine, so it has no folder yet. Follow [Before your first sync](#before-your-first-sync-important).

**Synced, but the session list didn't change.**
Quit Claude Desktop fully (not just the window) and reopen. The app reads the index at launch.

**A session I deleted came back.**
Expected by default. Sync only deletes elsewhere if you ran it with `--sync-deletes` (see [Syncing deletes (opt-in)](#syncing-deletes-opt-in)). Otherwise, the copies in your other accounts restore it (limitation 1 above).

**A session I unarchived got archived again.**
Expected. It's still archived in another account, and archived wins (limitation 2 above). Unarchive it in every account.

**A sync did something you didn't want.**
Run `claude-sync --revert`. Next time, preview with `claude-sync --dry-run` first.

**Windows: `claude-sync` is not recognized.**
Open a new terminal, or run `. $PROFILE`. If you use both Windows PowerShell and PowerShell 7, run the installer once in each (they have separate profiles).

**A session opens but looks unrelated / belongs to another org.**
Session indexes are synced across all account and org folders on the machine. If you keep strictly separated work and personal data, sync manually only when you need it (skip hands-off mode).

---

## License

MIT. See `LICENSE`.
