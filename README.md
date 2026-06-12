# claude-sync

**See all your Claude Code sessions, no matter which Claude account you're logged into.** Claude Desktop keeps a separate session index per account, so switching accounts makes your local session list look empty even though every transcript is still on disk. `claude-sync` copies the missing index entries across accounts: one command, additive only, nothing is ever overwritten or deleted.

Works on **macOS** and **Windows**. No dependencies, one script per platform.

---

> This is a small vibe-coded utility that copies files inside your own home folder. It can't break Claude (it never touches the app itself), but as always: read the script before you run it.

---

## The problem

You log into a second account in Claude Desktop and your Claude Code session list is suddenly empty. Your sessions are not gone:

- **Transcripts** live in `~/.claude/projects` and are shared by every account.
- **The session index** (what the desktop app's session list shows) is per account: `~/Library/Application Support/Claude/claude-code-sessions/<account-uuid>/<org-uuid>/local_*.json` on macOS, `%APPDATA%\Claude\claude-code-sessions\...` on Windows.

`claude-sync` copies every index file that exists under one account but not another, in both directions. After a restart of Claude, every account sees the full list.

---

## Before your first sync (important)

`claude-sync` can only see accounts that already have a session folder, and a freshly added account doesn't have one yet. So, once per new account:

1. **Log in** to the new account in Claude Desktop.
2. Open **Claude Code** and start one **throwaway session**. A plain "hi" is enough. This makes Claude create the session folder for that account, so `claude-sync` can recognize it.
3. **Quit** Claude Desktop.
4. Run `claude-sync`.
5. Reopen Claude. The full session list is there under the new account.

---

## Install & update

Same one-liner does both, fresh install or pulling the latest version. From then on, the `claude-sync` command works in every new terminal.

**macOS:**

```bash
curl -fsSLo /tmp/cs.sh https://raw.githubusercontent.com/SMKeramati/claude-sync/main/claude-sync.sh && chmod +x /tmp/cs.sh && /tmp/cs.sh --install && source ~/.zshrc
```

**Windows (PowerShell):**

```powershell
iwr -useb https://raw.githubusercontent.com/SMKeramati/claude-sync/main/claude-sync.ps1 -OutFile "$env:TEMP\claude-sync.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\claude-sync.ps1" -Install; . $PROFILE
```

Then:

```bash
claude-sync
```

That's it.

---

## Commands

| macOS | Windows | What it does |
|---|---|---|
| `claude-sync` | `claude-sync` | Run the sync. Idempotent, safe to re-run anytime. |
| `claude-sync --status` | `claude-sync -Status` | Show detected accounts, session counts, install state. |
| `claude-sync --install` | `claude-sync -Install` | Copy the script to `~/.claude/scripts/` and register the `claude-sync` command (zshrc alias / PowerShell profile function). Re-run to update. |
| `claude-sync --uninstall` | `claude-sync -Uninstall` | Remove the registered command (and the auto-sync agent on macOS). |
| `claude-sync --auto-install` | | Hands-off mode: auto-sync every time Claude Desktop quits. |
| `claude-sync --auto-uninstall` | | Disable hands-off mode. |
| `claude-sync --help` | `claude-sync -Help` | Print usage. |

---

## Hands-off mode (macOS, optional)

Don't want to remember to run `claude-sync` after switching accounts? One command wires up a LaunchAgent that watches for Claude Desktop quitting and syncs automatically:

```bash
claude-sync --auto-install      # enable
claude-sync --auto-uninstall    # disable
```

No sudo, no system changes: just a small bash loop (checks every few seconds) plus a plist in `~/Library/LaunchAgents/`. Log at `~/.claude/scripts/claude-sync.log`.

---

## How it works

1. Lists the account folders (one UUID directory per account) under Claude's `claude-code-sessions` data dir.
2. For every pair of accounts, copies each `local_*.json` session index file that exists in the source's org folder but is missing in the destination's.
3. That's all. The desktop app picks up the new index entries on next launch, and the transcripts they point to are already on disk (shared in `~/.claude/projects`).

---

## Safety

- **Additive only.** Copies files that don't exist at the destination. Never overwrites, never deletes.
- **Idempotent.** Re-run as often as you like; already-synced files are skipped.
- **Index only.** Your actual session transcripts in `~/.claude/projects` are never touched.
- **Only account folders are touched.** Anything else in the sessions dir (for example a `_shared` folder left by other sync tools or experiments) is skipped.
- **Sentinel-wrapped shell edits.** The command registration lives between `# >>> claude-sync shortcut >>>` markers in your zshrc / PowerShell profile, and uninstall removes exactly that block (with a timestamped backup first).

---

## Won't Claude fix this itself?

Maybe someday. As of June 2026, Claude Desktop keeps the local Claude Code session list strictly per account and doesn't merge it when you switch. Until that changes, `claude-sync` bridges the gap. The day it's obsolete, removal is one command (see below).

---

## Uninstall fully

**macOS:**

```bash
claude-sync --uninstall        # removes the alias and the auto-sync agent
rm ~/.claude/scripts/claude-sync.sh ~/.claude/scripts/claude-sync.log
```

**Windows:**

```powershell
claude-sync -Uninstall
Remove-Item "$HOME\.claude\scripts\claude-sync.ps1", "$HOME\.claude\scripts\claude-sync.log"
```

---

## Troubleshooting

**"Only one account folder found. Nothing to sync."**
The other account has never created a Claude Code session on this machine, so it has no folder yet. Follow [Before your first sync](#before-your-first-sync-important).

**Synced, but the session list didn't change.**
Quit Claude Desktop fully (not just the window) and reopen. The app reads the index at launch.

**Windows: `claude-sync` is not recognized.**
Open a new terminal, or run `. $PROFILE`. If you use both Windows PowerShell and PowerShell 7, run the installer once in each (they have separate profiles).

**A session opens but looks unrelated / belongs to another org.**
Session indexes are synced across all account and org folders on the machine. If you keep strictly separated work and personal data, sync manually only when you need it (skip hands-off mode).

---

## License

MIT. See `LICENSE`.
