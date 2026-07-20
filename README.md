# claude-sync

**See all your Claude Code sessions, no matter which Claude account you're logged into, and keep your local customization in sync across profiles.** Claude Desktop keeps a separate session index per account, so switching accounts makes your local session list look empty even though every transcript is still on disk. And if you run multiple profiles (for example with [claude-deck](https://github.com/smk-labs/claude-deck)), each profile has its own data dir, so a local MCP server you add in one profile does not exist in the others. `claude-sync` fixes both: install once with one command, then just run `claude-sync` (or let auto-sync do it for you).

**macOS** (`claude-sync.sh`) and **Windows** (`claude-sync.ps1`), one script per platform, no dependencies. The macOS script implements the v4 design (one shared session list through symlinks, plus self-healing of lost entries); the Windows script still implements the v3 copy-based sync, works on Windows PowerShell 5.1 and PowerShell 7+, and accepts both `-DryRun`-style switches and the macOS `--dry-run` spellings.

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

## What it does (macOS, v4)

Since v4 the macOS script does not copy session files around at all. It restructures once, then keeps the structure healthy:

- **One shared list.** All existing `local_*.json` list entries move into one folder, `claude-code-sessions/_shared`, and every `<account>/<org>` folder becomes a symlink to it. Every account sees the same list, a new conversation appears everywhere the moment the app writes it, and renames, archiving, and deletes are instantly true for all accounts because there is only one physical file per session. The whole "newest copy wins" reconciliation, its ledger, and its edge cases are gone.
- **Self-healing.** Claude Desktop sometimes never writes a list entry for a conversation (seen after restarts and rewound sessions), so it vanishes from the list even though the transcript in `~/.claude/projects` is intact. Every run scans the transcripts and regenerates any missing entry: title from your first message, folder and timestamps from the transcript. Existing entries are never edited or deleted; transcripts are only ever read.
- **New accounts absorbed.** When the app later creates a fresh real `<account>/<org>` folder (first session under a new account or org), the next run moves its entries into `_shared` and replaces it with a symlink too.
- **Profiles stay identical.** MCP servers (adds, edits, removals) and Desktop Extensions still sync across [claude-deck](https://github.com/smk-labs/claude-deck) profiles. On an edit conflict, the most recently edited config wins. See [Profiles](#profiles-claude-deck).
- **Safe by default.** The restructure only runs while Claude Desktop is fully closed (the script checks and stops otherwise), takes a backup of the whole `claude-code-sessions` tree first, and `claude-sync --revert` restores that tree exactly as it was. `claude-sync --dry-run` previews everything without writing a byte.

The old v3 limitations (un-archiving could not propagate; deletes needed a ledger and guards) no longer exist on macOS: with one physical list there is nothing to reconcile. Windows still runs the v3 copy-based sync, so those sections below apply to Windows only.

---

## Profiles (claude-deck)

If `~/Library/Application Support/Claude Profiles/` exists (Windows: `%APPDATA%\Claude Profiles\`), created by a multi-profile launcher such as claude-deck, every sync also reconciles local customization across all data dirs, in the same run and with the same safety rails (no profiles dir means this whole layer is dormant and costs nothing):

- **MCP servers.** The `mcpServers` block of every `claude_desktop_config.json` is fully reconciled. Add a server in one profile: it appears in every profile. Edit a server (change its command, args, env) in one profile: the edit propagates, and if two profiles disagree, the config file edited most recently wins. Remove a server in any profile: the next sync removes it everywhere (run with `--no-deletes` to skip that, or to bring back a server you removed by mistake). A small ledger (`~/.claude/scripts/mcp-ledger.tsv`) remembers which servers were synced everywhere, so "you removed it" is never confused with "a new profile never had it". Every other key of each config file (preferences, account state) is untouched. JSON handling runs in macOS's built-in `osascript` JavaScript runtime (called by absolute path, so a shadowed binary in `/usr/local/bin` can't interfere); on Windows it uses PowerShell's built-in `ConvertFrom-Json`/`ConvertTo-Json`: still no dependency.
- **Desktop Extensions.** Extension folders installed in one profile are copied to the profiles that lack them (best effort: some Claude builds may still want one enable-click in the new profile's settings).
- **Backed up and revertible.** Config overwrites land in the same run manifest as session writes, so `claude-sync --revert` restores them too, and `--dry-run` previews them.

Deliberately **not** synced: logins, cookies, and UI preferences: separate accounts are the whole point of profiles. Claude Code customization (plugins, skills, hooks, memory in `~/.claude`) is already machine-global and needs no syncing. Per-profile session dirs are claude-deck's job (it symlinks them to the shared one).

---

## Syncing deletes

**macOS (v4):** session deletes need no syncing anymore. There is one physical list, so deleting a session in the app deletes it for every account at once. `--no-deletes` on macOS only affects MCP server removals in the profile layer (see below).

**Windows (v3)** still propagates session deletes with backups and three guards: only sessions once fully synced everywhere qualify (the ledger), anything with newer activity is kept (the activity guard), and `--revert` brings deleted items back.

MCP server removals propagate on both platforms: remove a server in any profile and the next sync removes it everywhere. Two escape hatches:

```bash
claude-sync --dry-run       # preview, including what would be removed
claude-sync --no-deletes    # sync WITHOUT removals; a removed MCP server
                            # is restored from the profiles that still
                            # have it (undo a removal before it syncs)
```


---

## The problem

You log into a second account in Claude Desktop and your Claude Code session list is suddenly empty. Your sessions are not gone:

- **Transcripts** live in `~/.claude/projects` and are shared by every account.
- **The session index** (what the desktop app's session list shows) is per account: `~/Library/Application Support/Claude/claude-code-sessions/<account-uuid>/<org-uuid>/local_*.json` (Windows: `%APPDATA%\Claude\claude-code-sessions\...`).

On macOS, `claude-sync` replaces those per-account folders with symlinks to one shared folder, so there is nothing left to merge. On Windows it still merges the per-account indexes. Either way: after a restart of Claude, every account sees the same full, up-to-date list.

---

## Before your first sync (important)

`claude-sync` can only see accounts that already have a session folder, and a freshly added account doesn't have one yet. So, once per new account:

1. **Log in** to the new account in Claude Desktop.
2. Open **Claude Code** and start one **throwaway session**. A plain "hi" is enough. This makes Claude create the session folder for that account, so `claude-sync` can recognize it.
3. **Quit** Claude Desktop. On macOS this matters: the restructure (first run, or absorbing a new account's folder) refuses to run while the app is open.
4. Run `claude-sync`.
5. Reopen Claude. The full session list is there under the new account.

---

## Commands

Shown in macOS spelling; on Windows the same commands work both ways (`claude-sync --dry-run` or `claude-sync -DryRun`).

| Command | What it does |
|---|---|
| `claude-sync` | Run the sync. macOS: unify into `_shared` when needed (Claude must be closed for that), then regenerate lost list entries. Idempotent, safe to re-run anytime. |
| `claude-sync --dry-run` | Show everything a sync would do. Writes nothing, not even backups. |
| `claude-sync --no-deletes` | Sync without propagating MCP server removals; a removed server is restored from the profiles that still have it. (Windows: also skips session deletes.) |
| `claude-sync --revert` | Undo the last sync. If that run restructured the session tree, the whole tree is restored exactly as it was (entries the app wrote after the backup are salvaged into the restored folders, so nothing is lost). Run again to undo the run before that. |
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

macOS (v4), each run:

1. **Unify (only when needed).** If any `<account>/<org>` folder is still a real directory, the script requires Claude Desktop to be closed, backs up the whole `claude-code-sessions` tree, moves the union of all `local_*.json` into `_shared` (on a name collision the copy with the newer activity wins), and replaces each folder with a symlink to `_shared`. Already-linked folders are skipped, so this is a no-op after the first run until the app creates a new account/org folder.
2. **Self-heal.** Every transcript in `~/.claude/projects/*/*.jsonl` is checked against `_shared`. A transcript with no list entry gets one regenerated: title from the first user message, cwd, model, and timestamps from the transcript. Never overwrites, never deletes, never writes into `~/.claude`.

Windows (v3) still does inventory, pick winners by newest activity, distribute copies.

The desktop app picks up changes on next launch. The transcripts the list points to are already on disk, shared in `~/.claude/projects`, and are never touched.

---

## Safety

- **Closed-app gate.** The restructure moves the app's live folders, so it only runs while Claude Desktop is fully closed; otherwise the script stops with a clear message and changes nothing.
- **Whole-tree backup before restructuring.** Any run that touches the tree's structure first copies all of `claude-code-sessions` under `~/.claude/scripts/backups/<run>/`, with a manifest. The 10 most recent runs are kept.
- **One-command undo.** `claude-sync --revert` restores the tree from that backup exactly as it was, salvaging entries the app wrote after the backup so no session disappears. Run it again to step back one more run.
- **Self-heal is additive only.** Regenerated entries are new files; an existing entry is never edited or overwritten, and nothing under `~/.claude` is ever written by the session machinery.
- **Preview mode.** `claude-sync --dry-run` prints every planned action and writes nothing.
- **Index only.** Your actual session transcripts in `~/.claude/projects` are never touched.
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

**A session vanished from the list but the conversation exists.**
macOS: run `claude-sync`. The self-heal step regenerates the missing entry from the transcript.

**A session I deleted came back (Windows, v3).**
Two possibilities. Either it was never fully synced everywhere (the ledger won't allow deleting those, so other accounts restore it: sync once, then delete it again), or some copy of it had activity newer than the last sync (the activity guard kept it; the log says so). Delete it again and the next sync will propagate the delete.

**I deleted something by mistake and it's gone everywhere.**
`claude-sync --revert` undoes the whole last run. On Windows, if the deletion hasn't synced yet, run `claude-sync --no-deletes` instead: the surviving copies get copied back.

**A session I unarchived got archived again (Windows, v3).**
Expected there. It's still archived in another account, and archived wins. Unarchive it in every account. (macOS v4 has one physical list, so archive state is just what you set.)

**A sync did something you didn't want.**
Run `claude-sync --revert`. Next time, preview with `claude-sync --dry-run` first.

**A session opens but looks unrelated / belongs to another org.**
Session indexes are synced across all account and org folders on the machine. If you keep strictly separated work and personal data, sync manually only when you need it (skip hands-off mode).

---

## License

MIT. See `LICENSE`.
