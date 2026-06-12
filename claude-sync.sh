#!/bin/bash
# claude-sync: make local Claude Code sessions visible across all your
# Claude Desktop accounts on this Mac.
#
# Claude Desktop keeps a separate Claude Code session index per account
# (one UUID folder per account under ~/Library/Application Support/Claude/
# claude-code-sessions). Switch accounts and your session list looks empty,
# even though every transcript is still on disk in ~/.claude/projects.
# This script copies the missing index files across accounts.
# Additive only: it never overwrites and never deletes.
#
# Compatible with the stock macOS /bin/bash (3.2). No dependencies.
#
# https://github.com/SMKeramati/claude-sync

VERSION="1.0.0"

SESSIONS_DIR="$HOME/Library/Application Support/Claude/claude-code-sessions"
CANONICAL_DIR="$HOME/.claude/scripts"
CANONICAL_PATH="$CANONICAL_DIR/claude-sync.sh"
LOG="$CANONICAL_DIR/claude-sync.log"

RC_FILE="$HOME/.zshrc"
RC_BEGIN="# >>> claude-sync shortcut >>>"
RC_END="# <<< claude-sync shortcut <<<"

AGENT_LABEL="com.claude-sync.watcher"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

SOURCE_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ---------- output helpers ----------------------------------------------
if [ -t 1 ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; DIM=""; RESET=""
fi

log() {
  mkdir -p "$CANONICAL_DIR"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

die() { echo "${YELLOW}$*${RESET}" >&2; exit 1; }

# ---------- core sync ----------------------------------------------------
# Globs only, no find: on macOS, find (getattrlistbulk) can return empty
# results inside freshly created session dirs while plain readdir works.
collect_accounts() {
  # One UUID folder per account. Newer Claude builds also keep a "_shared"
  # cross-account store there; it is not an account, leave it alone.
  accounts=()
  for d in "$SESSIONS_DIR"/*/; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in _*) continue ;; esac
    accounts+=("${d%/}")
  done
}

count_index_files() {
  # $1: dir holding local_*.json directly, or account dir with org subdirs
  n=0
  for f in "$1"/local_*.json; do
    [ -f "$f" ] && n=$((n + 1))
  done
  for org in "$1"/*/; do
    [ -d "$org" ] || continue
    for f in "$org"local_*.json; do
      [ -f "$f" ] && n=$((n + 1))
    done
  done
  echo "$n"
}

do_sync() {
  if [ ! -d "$SESSIONS_DIR" ]; then
    log "Sessions folder not found: $SESSIONS_DIR"
    log "Open Claude Desktop, go to Claude Code, and start one session first."
    return 1
  fi

  collect_accounts

  if [ ${#accounts[@]} -lt 2 ]; then
    log "Only one account folder found. Nothing to sync."
    log "Tip: log in to your other account in Claude Desktop, start one"
    log "throwaway Claude Code session (a plain 'hi' is enough), quit Claude,"
    log "then run claude-sync again."
    return 0
  fi

  log "Syncing sessions across ${#accounts[@]} accounts..."
  total=0

  for src_account in "${accounts[@]}"; do
    for src_org in "$src_account"/*/; do
      [ -d "$src_org" ] || continue

      for dst_account in "${accounts[@]}"; do
        [ "$src_account" = "$dst_account" ] && continue

        for dst_org in "$dst_account"/*/; do
          [ -d "$dst_org" ] || continue

          count=0
          for f in "$src_org"local_*.json; do
            [ -f "$f" ] || continue
            fname=$(basename "$f")
            dst="$dst_org$fname"
            if [ ! -f "$dst" ]; then
              cp "$f" "$dst"
              count=$((count + 1))
              total=$((total + 1))
            fi
          done

          if [ "$count" -gt 0 ]; then
            log "  +$count session(s): $(basename "$src_account") -> $(basename "$dst_account")"
          fi
        done
      done
    done
  done

  log "Done. $total new session(s) synced."
  return 0
}

# ---------- watcher (hands-off mode) -------------------------------------
cmd_watch() {
  log "[watcher] Watcher started."
  while true; do
    # Wait for the Claude Desktop main process to be running
    while ! pgrep -x "Claude" > /dev/null 2>&1; do
      sleep 5
    done

    pid=$(pgrep -x "Claude" | head -1)
    log "[watcher] Claude detected (PID $pid). Waiting for quit..."

    # Wait for the main process to exit
    while kill -0 "$pid" 2>/dev/null; do
      sleep 2
    done

    # Brief grace period for helpers to clean up
    sleep 3

    log "[watcher] Claude quit. Running sync..."
    do_sync
  done
}

cmd_auto_install() {
  [ -f "$CANONICAL_PATH" ] || die "Run --install first ($CANONICAL_PATH not found)."
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$CANONICAL_PATH</string>
        <string>--watch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF
  launchctl unload "$AGENT_PLIST" 2>/dev/null
  launchctl load "$AGENT_PLIST"
  echo "${GREEN}Auto-sync enabled.${RESET} Sessions sync every time Claude Desktop quits."
  echo "${DIM}Log: $LOG${RESET}"
}

cmd_auto_uninstall() {
  if [ ! -f "$AGENT_PLIST" ]; then
    echo "${YELLOW}Auto-sync agent not installed. Nothing to do.${RESET}"
    return 0
  fi
  launchctl unload "$AGENT_PLIST" 2>/dev/null
  rm -f "$AGENT_PLIST"
  echo "${GREEN}Auto-sync disabled.${RESET}"
}

# ---------- install / uninstall ------------------------------------------
cmd_install() {
  mkdir -p "$CANONICAL_DIR"
  if [ "$SOURCE_PATH" = "$CANONICAL_PATH" ]; then
    echo "${DIM}Running from canonical location; script already in place.${RESET}"
  else
    echo "Installing script -> $CANONICAL_PATH"
    cp -f "$SOURCE_PATH" "$CANONICAL_PATH"
    chmod 755 "$CANONICAL_PATH"
  fi

  [ -e "$RC_FILE" ] || touch "$RC_FILE"
  if grep -qF "$RC_BEGIN" "$RC_FILE"; then
    echo "${YELLOW}Alias already present in $RC_FILE; leaving it alone.${RESET}"
    echo "${DIM}(Script at $CANONICAL_PATH was refreshed.)${RESET}"
  else
    echo "Adding 'claude-sync' alias to $RC_FILE"
    cat >> "$RC_FILE" <<EOF

$RC_BEGIN
alias claude-sync='bash "\$HOME/.claude/scripts/claude-sync.sh"'
$RC_END
EOF
  fi

  # If hands-off mode is on, restart the watcher so it runs the new script.
  if [ -f "$AGENT_PLIST" ]; then
    echo "Restarting auto-sync agent with the updated script..."
    launchctl unload "$AGENT_PLIST" 2>/dev/null
    launchctl load "$AGENT_PLIST"
  fi

  echo "${GREEN}Installed.${RESET} Run: source ~/.zshrc && claude-sync"
}

cmd_uninstall() {
  if [ -f "$AGENT_PLIST" ]; then
    cmd_auto_uninstall
  fi
  if [ ! -f "$RC_FILE" ] || ! grep -qF "$RC_BEGIN" "$RC_FILE"; then
    echo "${YELLOW}No shortcut block found in $RC_FILE. Nothing to remove.${RESET}"
    return 0
  fi
  echo "Removing 'claude-sync' alias from $RC_FILE"
  cp "$RC_FILE" "$RC_FILE.bak.$(date +%s)"
  awk -v b="$RC_BEGIN" -v e="$RC_END" '
    index($0, b) {skip=1; next}
    index($0, e) {skip=0; next}
    !skip
  ' "$RC_FILE" > "$RC_FILE.tmp" && mv "$RC_FILE.tmp" "$RC_FILE"
  echo "${GREEN}Removed.${RESET} Open a new terminal for it to take effect."
  echo "${DIM}To delete the script and log too:${RESET}"
  echo "${DIM}  rm \"$CANONICAL_PATH\" \"$LOG\"${RESET}"
}

# ---------- status / help -------------------------------------------------
cmd_status() {
  echo "claude-sync v$VERSION"
  echo "Sessions dir: $SESSIONS_DIR"
  if [ ! -d "$SESSIONS_DIR" ]; then
    echo "  ${YELLOW}(not found: open Claude Code in Claude Desktop once)${RESET}"
    return 1
  fi
  collect_accounts
  for d in "${accounts[@]}"; do
    echo "  account $(basename "$d"): $(count_index_files "$d") session index file(s)"
  done
  if [ -d "$SESSIONS_DIR/_shared" ]; then
    echo "  ${DIM}_shared (Claude's own cross-account store, untouched): $(count_index_files "$SESSIONS_DIR/_shared") file(s)${RESET}"
  fi
  if [ -f "$CANONICAL_PATH" ]; then
    echo "Script: installed at $CANONICAL_PATH"
  else
    echo "Script: not installed (run --install)"
  fi
  if [ -f "$RC_FILE" ] && grep -qF "$RC_BEGIN" "$RC_FILE"; then
    echo "Alias: registered in $RC_FILE"
  else
    echo "Alias: not registered"
  fi
  if launchctl list 2>/dev/null | grep -qF "$AGENT_LABEL"; then
    echo "Auto-sync: enabled (syncs when Claude Desktop quits)"
  else
    echo "Auto-sync: disabled"
  fi
}

usage() {
  cat <<EOF
claude-sync v$VERSION
Make local Claude Code sessions visible across all Claude Desktop accounts.

Usage: claude-sync [command]

  (no command)       Run the sync.
  --status           Show detected accounts, session counts, install state.
  --install          Copy this script to ~/.claude/scripts/ and register the
                     'claude-sync' alias in ~/.zshrc. Re-run to update.
  --uninstall        Remove the alias and the auto-sync agent (if enabled).
  --auto-install     Auto-sync every time Claude Desktop quits (LaunchAgent).
  --auto-uninstall   Disable auto-sync.
  --version          Print version.
  --help             This text.

Before the first sync: log in to the new account in Claude Desktop, start
one throwaway Claude Code session ('hi' is enough), quit Claude, then sync.
EOF
}

# ---------- dispatcher ----------------------------------------------------
case "${1:-}" in
  "")                do_sync; exit $? ;;
  --install)         cmd_install ;;
  --uninstall)       cmd_uninstall ;;
  --auto-install)    cmd_auto_install ;;
  --auto-uninstall)  cmd_auto_uninstall ;;
  --watch)           cmd_watch ;;
  --status)          cmd_status ;;
  --version|-v)      echo "claude-sync v$VERSION" ;;
  --help|-h)         usage ;;
  *)                 usage; exit 1 ;;
esac
