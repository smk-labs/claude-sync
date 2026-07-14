# claude-sync

**See all your Claude Code sessions, no matter which Claude account you're logged into, and keep your local customization in sync across profiles.** Claude Desktop keeps a separate session index per account, so switching accounts makes your local session list look empty even though every transcript is still on disk. And if you run multiple profiles (for example with [claude-deck](https://github.com/smk-labs/claude-deck)), each profile has its own data dir, so a local MCP server you add in one profile does not exist in the others. `claude-sync` fixes both: install once with one command, then just run `claude-sync` (or let auto-sync do it for you).

**macOS** (`claude-sync.sh`) and **Windows** (`claude-sync.ps1`), one script per platform, no dependencies. Both implement the same v3 behavior; the Windows script works on Windows PowerShell 5.1 and PowerShell 7+ and accepts both `-DryRun`-style switches and the macOS `--dry-run` spellings.

---

> This is a small vibe-coded utility that copies files inside your own home folder. It can't break Claude (it never touches the app itself), but as always: read the script before you run it.

---

## Install & update

Same one-liner does both, fresh install or pulling the latest version. From then on, the `claude-sync` command works in every new terminal.

macOS:

```bash
curl -fsSLo /tmp/cs.sh https://raw.githubusercontent.com/smk-labs/claude-sync/main/claude-sync.sh && chmod +x /tmp/cs.sh && /tmp/cs.sh --install && source ~/.zshrc
```

Windows (PowerShell):

```powershell
iwr -useb https://raw.githubusercontent.com/smk-labs/claude-sync/main/claude-sync.ps1 -OutFile "$env:TEMP\cs.ps1"; & "$env:TEMP\cs.ps1" -Install
```

Then, in a new terminal:

```bash
claude-sync
```

That's it.

---

## What it does

A full two-way sync, not a one-way copy:

- **Sessions update everywhere, not just appear.** Continue or rename a session in one account and every other account gets the newer version. Newest activity wins.
- **Archiving propagates.** Archive a session in one account and the next sync archives it in all accounts.
- **Deletes propagate.** Delete a session in any account and the next sync deletes it everywhere, guarded and backed up. `--no-deletes` turns that off per run and doubles as the restore path. See [Syncing deletes](#syncing-deletes).
- **Profiles stay identical.** MCP servers (adds, edits, removals) and Desktop Extensions sync across [claude-deck](https://github.com/smk-labs/claude-deck) profiles. On an edit conflict, the most recently edited config wins. See [Profiles](#profiles-claude-deck).
- **Safe by default.** Every file a sync changes is backed up first, `claude-sync --revert` undoes the last run completely, and `claude-sync --dry-run` previews everything without writing a byte.
- **Honest summary numbers.** The report counts sessions, not file copies. "3 new, 5 updated" means 3 sessions and 5 sessions, not the 36 files behind them.
- **Fast.** One single pass over all files instead of comparing every account against every other one.

### One honest limitation

**Un-archiving does not propagate.** If a session is still archived in *any* account, the next sync archives it everywhere again. To truly unarchive a session, unarchive it in every account (or unarchive it and don't sync).

---

## Profiles (claude-deck)

If `~/Library/Application Support/Claude Profiles/` exists (Windows: `%APPDATA%\Claude Profiles\`), created by a multi-profile launcher such as claude-deck, every sync also reconciles local customization across all data dirs, in the same run and with the same safety rails (no profiles dir means this whole layer is dormant and costs nothing):

- **MCP servers.** The `mcpServers` block of every `claude_desktop_config.json` is fully reconciled. Add a server in one profile: it appears in every profile. Edit a server (change its command, args, env) in one profile: the edit propagates, and if two profiles disagree, the config file edited most recently wins. Remove a server in any profile: the next sync removes it everywhere (run with `--no-deletes` to skip that, or to bring back a server you removed by mistake). A small ledger (`~/.claude/scripts/mcp-ledger.tsv`) remembers which servers were synced everywhere, so "you removed it" is never confused with "a new profile never had it". Every other key of each config file (preferences, account state) is untouched. JSON handling runs in macOS's built-in `osascript` JavaScript runtime (called by absolute path, so a shadowed binary in `/usr/local/bin` can't interfere); on Windows it uses PowerShell's built-in `ConvertFrom-Json`/`ConvertTo-Json`: still no dependency.
- **Desktop Extensions.** Extension folders installed in one profile are copied to the profiles that lack them (best effort: some Claude builds may still want one enable-click in the new profile's settings).
- **Backed up and revertible.** Config overwrites land in the same run manifest as session writes, so `claude-sync --revert` restores them too, and `--dry-run` previews them.

Deliberately **not** synced: logins, cookies, and UI preferences: separate accounts are the whole point of profiles. Claude Code customization (plugins, skills, hooks, memory in `~/.claude`) is already machine-global and needs no syncing. Per-profile session dirs are claude-deck's job (it symlinks them to the shared one).

---

## Syncing deletes

Since v2.3, deletes propagate by default: delete a session in any account (or remove an MCP server in any profile) and the next sync deletes it everywhere. This includes auto-sync. It's safe to have on because every deletion is backed up first and three guards watch over it:

- **The ledger.** Only sessions that were once fully synced across every account can be deleted by sync. A session that simply hasn't reached an account yet is copied there, never mistaken for a delete.
- **The activity guard.** If any surviving copy shows activity newer than the last full sync, the session is kept (the deletion may predate that activity).
- **Backups.** `claude-sync --revert` brings deleted sessions and MCP servers back, the same way it undoes any other sync.

Two escape hatches:

```bash
claude-sync --dry-run       # preview, including what would be deleted
claude-sync --no-deletes    # sync WITHOUT deletes; deleted items get
                            # restored from the accounts that still have
                            # them (undo a deletion before it propagates)
```


---

## The problem

You log into a second account in Claude Desktop and your Claude Code session list is suddenly empty. Your sessions are not gone:

- **Transcripts** live in `~/.claude/projects` and are shared by every account.
- **The session index** (what the desktop app's session list shows) is per account: `~/Library/Application Support/Claude/claude-code-sessions/<account-uuid>/<org-uuid>/local_*.json` (Windows: `%APPDATA%\Claude\claude-code-sessions\...`).

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

Shown in macOS spelling; on Windows the same commands work both ways (`claude-sync --dry-run` or `claude-sync -DryRun`).

| Command | What it does |
|---|---|
| `claude-sync` | Run the sync (deletes propagate by default; see [Syncing deletes](#syncing-deletes)). Idempotent, safe to re-run anytime. |
| `claude-sync --dry-run` | Show everything a sync would create, overwrite, or delete. Writes nothing, not even backups. |
| `claude-sync --no-deletes` | Sync without propagating deletes; restores anything deleted on one side from the surviving copies (see [Syncing deletes](#syncing-deletes)). |
| `claude-sync --revert` | Undo the last sync: delete the files it created, restore the files it overwrote or deleted. Run again to undo the sync before that. |
| `claude-sync --status` | Show detected accounts and profiles, session and MCP server counts, install state, last sync time, stored backup runs. |
| `claude-sync --install` | Copy the script to `~/.claude/scripts/` and register the `claude-sync` alias in `~/.zshrc`. Re-run to update. |
| `claude-sync --uninstall` | Remove the alias (and the auto-sync watcher). |
| `claude-sync --auto-install` | Hands-off mode: auto-sync every time Claude Desktop quits. |
| `claude-sync --auto-uninstall` | Disable hands-off mode. |
| `claude-sync --version` | Print the version. |
| `claude-sync --help` | Print usage. |

---

## Hands-off mode (optional)

Don't want to remember to run `claude-sync` after switching accounts? One command wires up a watcher that syncs automatically after Claude Desktop quits:

```bash
claude-sync --auto-install      # enable
claude-sync --auto-uninstall    # disable
```

On macOS this is a LaunchAgent (a small bash loop that checks every few seconds, plus a plist in `~/Library/LaunchAgents/`); on Windows it is a per-user Scheduled Task running the same watcher loop. No sudo, no admin rights, no system changes. Log at `~/.claude/scripts/claude-sync.log`. The watcher syncs with the default settings, deletes included.

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
- **Deletes are guarded.** Deletion propagation only touches sessions the ledger saw fully synced everywhere, skips anything with newer activity, backs everything up first, and can be turned off per run with `--no-deletes` (see [Syncing deletes](#syncing-deletes)).
- **Preview mode.** `claude-sync --dry-run` prints every planned action and the summary, and writes nothing.
- **Index only.** Your actual session transcripts in `~/.claude/projects` are never touched.
- **Only account folders are touched.** Anything else in the sessions dir (for example a `_shared` folder left by other sync tools or experiments) is skipped and never written into.
- **Sentinel-wrapped shell edits.** The command registration lives between `# >>> claude-sync shortcut >>>` markers in your zshrc, and uninstall removes exactly that block (with a timestamped backup first).

---

## Won't Claude fix this itself?

Maybe someday. As of mid 2026, Claude Desktop keeps the local Claude Code session list strictly per account and doesn't merge it when you switch. Until that changes, `claude-sync` bridges the gap. The day it's obsolete, removal is one command (see below).

---

## Uninstall fully

```bash
claude-sync --uninstall        # removes the alias and the auto-sync agent
rm -rf ~/.claude/scripts/claude-sync.sh ~/.claude/scripts/claude-sync.log ~/.claude/scripts/backups
```

Windows: `claude-sync -Uninstall`, then delete `~\.claude\scripts\claude-sync.ps1` plus the log, ledgers and `backups\` folder next to it (the uninstall output prints the exact command).

---

## Troubleshooting

**"Only one account folder found. Nothing to sync."**
The other account has never created a Claude Code session on this machine, so it has no folder yet. Follow [Before your first sync](#before-your-first-sync-important).

**Synced, but the session list didn't change.**
Quit Claude Desktop fully (not just the window) and reopen. The app reads the index at launch.

**A session I deleted came back.**
Two possibilities. Either it was never fully synced everywhere (the ledger won't allow deleting those, so other accounts restore it: sync once, then delete it again), or some copy of it had activity newer than the last sync (the activity guard kept it; the log says so). Delete it again and the next sync will propagate the delete.

**I deleted something by mistake and it's gone everywhere.**
`claude-sync --revert` undoes the whole last run, deletions included. If the deletion hasn't synced yet, run `claude-sync --no-deletes` instead: the surviving copies get copied back.

**A session I unarchived got archived again.**
Expected. It's still archived in another account, and archived wins (limitation 2 above). Unarchive it in every account.

**A sync did something you didn't want.**
Run `claude-sync --revert`. Next time, preview with `claude-sync --dry-run` first.

**A session opens but looks unrelated / belongs to another org.**
Session indexes are synced across all account and org folders on the machine. If you keep strictly separated work and personal data, sync manually only when you need it (skip hands-off mode).

---

## License

MIT. See `LICENSE`.
