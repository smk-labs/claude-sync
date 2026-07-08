#!/bin/bash
# claude-sync: make local Claude Code sessions visible across all your
# Claude Desktop accounts on this Mac.
#
# Claude Desktop keeps a separate Claude Code session index per account
# (one UUID folder per account under ~/Library/Application Support/Claude/
# claude-code-sessions). Switch accounts and your session list looks empty,
# even though every transcript is still on disk in ~/.claude/projects.
# This script reconciles the index files across accounts:
#   - the copy with the newest lastActivityAt wins,
#   - archived-in-one means archived-everywhere,
#   - every overwrite is backed up first and can be undone with --revert,
#   - by default nothing is ever deleted. (Corollary: deleting a session in
#     one account does not delete it elsewhere, and the next sync brings it
#     back.) Opt-in deletion propagation is available with --sync-deletes;
#     see the ledger machinery below.
#
# It also syncs customization across PROFILES: multi-profile launchers
# (claude-deck) give each profile its own data dir under
# ~/Library/Application Support/Claude Profiles/<name>/, so local MCP
# servers (the mcpServers block of claude_desktop_config.json) and installed
# Desktop Extensions diverge per profile. Every sync unions mcpServers
# across all data dirs (additive; the default profile wins a name conflict;
# every other key is untouched) and copies missing extensions. Config writes
# are backed up into the run's manifest, so --revert undoes them too.
# Logins, cookies, and UI preferences are deliberately never synced:
# separate accounts are the whole point of profiles. Claude Code
# customization (plugins, skills, hooks, memory in ~/.claude) is already
# machine-global and needs no syncing. Session dirs inside profiles are
# claude-deck's job (it symlinks them to the shared one), not ours.
#
# Compatible with the stock macOS /bin/bash (3.2). No dependencies
# (JSON merging runs in macOS's built-in osascript JavaScript runtime).
#
# https://github.com/SMKeramati/claude-sync

VERSION="2.2.0"

# Absolute path: /usr/local/bin may shadow osascript with a wrapper (seen in
# the wild: a VPN toggle shim), and LaunchAgent PATH is minimal anyway.
OSASCRIPT="/usr/bin/osascript"

# CLAUDE_SYNC_SESSIONS_DIR / CLAUDE_SYNC_HOME (and the two profile-root
# overrides) exist so tests can point the script at a throwaway tree
# instead of the real one.
SESSIONS_DIR="${CLAUDE_SYNC_SESSIONS_DIR:-$HOME/Library/Application Support/Claude/claude-code-sessions}"
DEFAULT_ROOT="${CLAUDE_SYNC_DEFAULT_ROOT:-$HOME/Library/Application Support/Claude}"
PROFILES_DIR="${CLAUDE_SYNC_PROFILES_DIR:-$HOME/Library/Application Support/Claude Profiles}"
CANONICAL_DIR="${CLAUDE_SYNC_HOME:-$HOME/.claude/scripts}"
CANONICAL_PATH="$CANONICAL_DIR/claude-sync.sh"
LOG="$CANONICAL_DIR/claude-sync.log"
BACKUPS_DIR="$CANONICAL_DIR/backups"
BACKUP_KEEP=10
LEDGER="$CANONICAL_DIR/ledger.tsv"
# Companion file, not part of the ledger.tsv row format: the account names
# that were part of the "present in every account" computation the last
# time the ledger was written. Needed so a brand-new account joining after
# the ledger was last written is never mistaken for "had this session and
# it got deleted" -- see compute_deletions.
LEDGER_ACCOUNTS="$CANONICAL_DIR/.ledger-accounts.tsv"

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

# ---------- account discovery --------------------------------------------
# Globs only, no find: on macOS, find (getattrlistbulk) can return empty
# results inside freshly created session dirs while plain readdir works.
collect_accounts() {
  # One UUID folder per account. Skip non-account dirs like "_shared"
  # (left behind by other sync experiments/tools); they are not accounts
  # and must never be written into.
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

# ---------- profile customization sync ------------------------------------
collect_roots() {
  # Every Claude data dir on this machine: the default one, plus one per
  # profile when a multi-profile launcher (claude-deck) is in use. The
  # default root comes first so its definitions win union conflicts.
  roots=("$DEFAULT_ROOT")
  for d in "$PROFILES_DIR"/*/; do
    [ -d "$d" ] || continue
    roots+=("${d%/}")
  done
}

ensure_run_dir() {
  # Backups for THIS run live in one dir with one manifest, shared by the
  # session plan executor and the profile config sync, so --revert undoes
  # a whole run no matter which layer wrote. Created lazily on first write.
  [ -n "${RUN_DIR:-}" ] && return 0
  RUN_DIR="$BACKUPS_DIR/$(date +%s)"
  MANIFEST="$RUN_DIR/manifest.tsv"
  mkdir -p "$RUN_DIR"
  : > "$MANIFEST"
}

sync_mcp_servers() {
  # Union the mcpServers block of claude_desktop_config.json across every
  # root, additively: a server missing from a root is added; nothing is
  # ever removed or overwritten (the default root is passed first, so its
  # definition wins a name conflict), and every other key of each file is
  # preserved. $1 = "dry" prints the plan and writes nothing. Real writes
  # back the previous file into the run manifest as an overwrite, so
  # --revert restores it. JSON runs in osascript's JS runtime: no deps.
  mode="$1"
  [ ${#roots[@]} -lt 2 ] && return 0

  cfg_files=()
  for root in "${roots[@]}"; do
    cfg="$root/claude_desktop_config.json"
    if [ ! -f "$cfg" ]; then
      [ "$mode" = "dry" ] && continue
      printf '{}\n' > "$cfg" 2>/dev/null || continue
    fi
    cfg_files+=("$cfg")
  done
  [ ${#cfg_files[@]} -lt 2 ] && return 0

  plan_out=$("$OSASCRIPT" -l JavaScript - "${cfg_files[@]}" 2>&1 <<'JXA'
function run(argv) {
  ObjC.import('Foundation');
  function read(p) {
    var s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, $());
    return s.isNil() ? null : ObjC.unwrap(s);
  }
  var union = {}, order = [], out = [];
  for (var i = 0; i < argv.length; i++) {
    var t = read(argv[i]), j;
    try { j = t ? JSON.parse(t) : {}; }
    catch (e) { return 'ERR not valid JSON, profile sync skipped: ' + argv[i]; }
    var m = j.mcpServers || {};
    for (var k in m) { if (!(k in union)) { union[k] = m[k]; order.push(k); } }
  }
  if (order.length === 0) return '';
  for (var i = 0; i < argv.length; i++) {
    var t = read(argv[i]), j = t ? JSON.parse(t) : {};
    var m = j.mcpServers || {}, added = [];
    for (var q = 0; q < order.length; q++) {
      if (!(order[q] in m)) added.push(order[q]);
    }
    if (added.length) out.push(argv[i] + '\t' + added.join(','));
  }
  return out.join('\n');
}
JXA
  )

  case "$plan_out" in
    ERR*) log "MCP servers: ${plan_out#ERR }"; return 0 ;;
    "")   return 0 ;;
  esac

  # Plan is known: in dry mode just narrate it; otherwise back up every
  # file the write pass will touch, into this run's backup dir.
  while IFS=$'\t' read -r cfg added; do
    [ -n "$cfg" ] || continue
    if [ "$mode" = "dry" ]; then
      echo "  ${DIM}would add MCP server(s)${RESET} [$added] -> $cfg"
      continue
    fi
    ensure_run_dir
    mkdir -p "$RUN_DIR/configs"
    cp -p "$cfg" "$RUN_DIR/configs/$(echo "$cfg" | tr '/' '_')"
  done <<EOF_PLAN
$plan_out
EOF_PLAN

  if [ "$mode" = "dry" ]; then
    return 0
  fi

  merge_out=$("$OSASCRIPT" -l JavaScript - "${cfg_files[@]}" 2>&1 <<'JXA3'
function run(argv) {
  ObjC.import('Foundation');
  function read(p) {
    var s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, $());
    return s.isNil() ? null : ObjC.unwrap(s);
  }
  function write(p, s) {
    $(s).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, $());
  }
  var cfgs = [], union = {}, order = [], out = [];
  for (var i = 0; i < argv.length; i++) {
    var t = read(argv[i]), j;
    try { j = t ? JSON.parse(t) : {}; }
    catch (e) { return 'ERR not valid JSON, profile sync skipped: ' + argv[i]; }
    cfgs.push(j);
    var m = j.mcpServers || {};
    for (var k in m) { if (!(k in union)) { union[k] = m[k]; order.push(k); } }
  }
  for (var i = 0; i < argv.length; i++) {
    var j = cfgs[i], m = j.mcpServers || {}, added = [];
    for (var q = 0; q < order.length; q++) {
      var k = order[q];
      if (!(k in m)) { m[k] = union[k]; added.push(k); }
    }
    if (added.length) {
      j.mcpServers = m;
      write(argv[i], JSON.stringify(j, null, 2) + '\n');
      out.push('+' + added.length + ' MCP server(s) [' + added.join(', ') + '] -> ' + argv[i]);
    }
  }
  return out.join('\n');
}
JXA3
  )
  case "$merge_out" in
    ERR*) log "MCP servers: ${merge_out#ERR }"; return 0 ;;
  esac
  if [ -n "$merge_out" ]; then
    while IFS= read -r line; do
      log "  $line"
      cfg_path="${line##*-> }"
      printf 'overwrote\t%s\t%s\n' "$cfg_path" "$RUN_DIR/configs/$(echo "$cfg_path" | tr '/' '_')" >> "$MANIFEST"
    done <<EOF_OUT
$merge_out
EOF_OUT
  fi
}

sync_extensions() {
  # Copy installed Desktop Extensions across roots, additively. Best
  # effort: a Claude build that also tracks extensions in per-profile
  # preferences may still want one enable-click in that profile.
  mode="$1"
  [ ${#roots[@]} -lt 2 ] && return 0
  copied=0
  for src_root in "${roots[@]}"; do
    src_ext="$src_root/Claude Extensions"
    [ -d "$src_ext" ] || continue
    for ext in "$src_ext"/*/; do
      [ -d "$ext" ] || continue
      name=$(basename "$ext")
      for dst_root in "${roots[@]}"; do
        [ "$src_root" = "$dst_root" ] && continue
        dst="$dst_root/Claude Extensions/$name"
        if [ ! -e "$dst" ]; then
          if [ "$mode" = "dry" ]; then
            echo "  ${DIM}would copy extension${RESET} $name -> $(basename "$dst_root")"
            copied=$((copied + 1))
            continue
          fi
          mkdir -p "$dst_root/Claude Extensions"
          if cp -R "${ext%/}" "$dst"; then
            ensure_run_dir
            printf 'created\t%s\n' "$dst" >> "$MANIFEST"
            copied=$((copied + 1))
          fi
        fi
      done
    done
  done
  if [ "$copied" -gt 0 ] && [ "$mode" != "dry" ]; then
    log "Extensions: $copied copied across profiles."
  fi
  return 0
}

sync_profiles() {
  # Orchestrates the profile layer. Fast, runs before the session machinery,
  # and independent of it (profiles exist even with a single account).
  mode="$1"
  collect_roots
  [ ${#roots[@]} -lt 2 ] && return 0
  sync_mcp_servers "$mode"
  sync_extensions "$mode"
}

# ---------- sync core ------------------------------------------------------
# Two passes over the whole tree, O(total files). v1 looped
# src-account x dst-account x dst-org x file (~70k existence checks plus a
# basename subshell each); v2 reads every file exactly once and plans all
# copies from that inventory.
#
# All intermediate state lives in $WORK_DIR (a mktemp dir, removed on exit):
#   orgdirs.tsv   account<TAB>org<TAB>orgPath      (every destination dir)
#   inv.tsv       fname<TAB>ts<TAB>arch<TAB>account<TAB>org<TAB>path
#   winners.tsv   fname<TAB>winnerTs<TAB>archOR<TAB>winnerArch<TAB>winnerPath
#   staged/       archive-flipped copies of winners (canonical when present)
#   plan.tsv      verb<TAB>flags<TAB>fname<TAB>src<TAB>dst<TAB>account<TAB>org
# Paths contain spaces ("Application Support") but never tabs or newlines,
# so TSV is a safe interchange format as long as every expansion is quoted.

build_inventory() {
  # Pass 1: one row per index file with the two fields sync decisions need.
  # The tree holds ~6,300 files; expanding one glob over all of them onto a
  # single command line exceeds macOS ARG_MAX ("Argument list too long").
  # So: globs write NUL-separated paths to a file, and xargs -0 feeds them
  # to awk in as many batches as fit.
  : > "$WORK_DIR/paths.nul"
  : > "$WORK_DIR/orgdirs.tsv"

  for acct in "${accounts[@]}"; do
    acct_name=$(basename "$acct")
    for org in "$acct"/*/; do
      [ -d "$org" ] || continue
      printf '%s\t%s\t%s\n' "$acct_name" "$(basename "$org")" "${org%/}" >> "$WORK_DIR/orgdirs.tsv"
      for f in "$org"local_*.json; do
        [ -f "$f" ] || continue
        printf '%s\0' "$f" >> "$WORK_DIR/paths.nul"
      done
    done
  done

  : > "$WORK_DIR/inv.tsv"
  [ -s "$WORK_DIR/paths.nul" ] || return 0

  # Index JSON is compact single-line with NO trailing newline, so line-based
  # reading would miss the record. RS is set to a byte that never appears in
  # the files, making each file exactly one awk record (FNR==1). Account and
  # org are the last two directory components of the path.
  xargs -0 awk -v OFS='\t' '
    BEGIN { RS = "\3" }
    FNR == 1 {
      n = split(FILENAME, comp, "/")
      ts = 0
      if (match($0, /"lastActivityAt":[0-9]+/)) {
        t = substr($0, RSTART, RLENGTH)
        sub(/^"lastActivityAt":/, "", t)
        ts = t + 0
      }
      print comp[n], ts, ($0 ~ /"isArchived":true/) ? 1 : 0, comp[n-2], comp[n-1], FILENAME
    }
  ' < "$WORK_DIR/paths.nul" >> "$WORK_DIR/inv.tsv"
}

reduce_winners() {
  # Pass 2: per session (fname), the newest copy wins (ties: first seen),
  # and archived state is OR-ed across all copies. The OR is deliberate:
  # archived in even one account means archived everywhere. Known accepted
  # caveat: un-archiving cannot propagate in v2.
  awk -F'\t' -v OFS='\t' '
    {
      f = $1; ts = $2 + 0
      if (!(f in wts)) { order[++n] = f; wts[f] = ts; warch[f] = $3; wpath[f] = $6 }
      else if (ts > wts[f]) { wts[f] = ts; warch[f] = $3; wpath[f] = $6 }
      if ($3 == 1) aor[f] = 1
    }
    END {
      for (i = 1; i <= n; i++) {
        f = order[i]
        print f, wts[f], (f in aor) ? 1 : 0, warch[f], wpath[f]
      }
    }
  ' "$WORK_DIR/inv.tsv" > "$WORK_DIR/winners.tsv"
}

stage_archived() {
  # Sessions archived somewhere but whose winner says "isArchived":false get
  # a staged copy with the flag flipped; the staged file becomes the
  # canonical source. The pattern occurs exactly once (machine-generated
  # JSON), and command substitution strips any trailing newline sed adds,
  # preserving the exact no-trailing-newline format. touch -r keeps the
  # winner's mtime on the staged copy so copy mtimes stay meaningful.
  mkdir -p "$WORK_DIR/staged"
  while IFS=$'\t' read -r fname ts aor warch wpath; do
    if [ "$aor" = "1" ] && [ "$warch" = "0" ]; then
      printf '%s' "$(sed 's/"isArchived":false/"isArchived":true/' "$wpath")" > "$WORK_DIR/staged/$fname"
      touch -r "$wpath" "$WORK_DIR/staged/$fname"
    fi
  done < "$WORK_DIR/winners.tsv"
}

build_plan() {
  # Cross every destination org dir with every session, decide from the
  # inventory alone (files are never re-read here). Flags mark why, per
  # session, for honest counting later: n=new somewhere, u=updated to a
  # newer state, a=archived state propagated.
  # A staged (archive-flipped) canonical differs from every non-archived
  # copy, so such destinations are updated even when their ts equals the
  # winner's.
  awk -F'\t' -v OFS='\t' \
      -v WIN="$WORK_DIR/winners.tsv" -v INV="$WORK_DIR/inv.tsv" \
      -v STAGED="$WORK_DIR/staged" '
    FILENAME == WIN {
      f = $1
      order[++n] = f
      wts[f] = $2 + 0; aor[f] = $3 + 0
      src[f] = ($3 + 0 == 1 && $4 + 0 == 0) ? STAGED "/" f : $5
      next
    }
    FILENAME == INV {
      key = $4 SUBSEP $5 SUBSEP $1
      its[key] = $2 + 0; iarch[key] = $3 + 0
      next
    }
    { m++; od_acct[m] = $1; od_org[m] = $2; od_path[m] = $3 }
    END {
      for (j = 1; j <= m; j++) {
        for (i = 1; i <= n; i++) {
          f = order[i]
          key = od_acct[j] SUBSEP od_org[j] SUBSEP f
          dst = od_path[j] "/" f
          if (!(key in its)) {
            print "create", "n", f, src[f], dst, od_acct[j], od_org[j]
          } else {
            flags = ""
            if (its[key] < wts[f]) flags = "u"
            if (aor[f] == 1 && iarch[key] == 0) flags = flags "a"
            if (flags != "")
              print "overwrite", flags, f, src[f], dst, od_acct[j], od_org[j]
          }
        }
      }
    }
  ' "$WORK_DIR/winners.tsv" "$WORK_DIR/inv.tsv" "$WORK_DIR/orgdirs.tsv" > "$WORK_DIR/plan.tsv"
}

compute_deletions() {
  # Only called when --sync-deletes is on. Finds sessions that qualify for
  # deletion everywhere (per the addendum's four-part rule) using nothing
  # but inv.tsv (this run's inventory), the ledger (last full-sync record),
  # and the account list. Writes:
  #   deletions.tsv   fname of every qualifying session (one per line)
  #   delete_rows.tsv verb=delete plan rows for every surviving copy, in the
  #                   same 7-column shape build_plan emits, so execute_plan
  #                   needs no new parsing logic.
  # Kept-by-activity-guard sessions get one explanatory log line each,
  # printed immediately (dry-run uses echo, real runs use log: same "emit"
  # convention as plan_summary).
  emit="$1"
  : > "$WORK_DIR/accounts.tsv"
  for a in "${accounts[@]}"; do
    basename "$a" >> "$WORK_DIR/accounts.tsv"
  done

  : > "$WORK_DIR/ledger_clean.tsv"
  if [ -f "$LEDGER" ]; then
    # Skip malformed rows outright: wrong column count or non-numeric ts
    # must never be treated as a match (addendum safety invariant).
    awk -F'\t' 'NF == 2 && $2 ~ /^[0-9]+$/ { print }' "$LEDGER" > "$WORK_DIR/ledger_clean.tsv"
  fi

  # The denominator for "present everywhere" is the INTERSECTION of two
  # account sets, because each set alone has a catastrophic failure mode:
  # - Accounts recorded at the ledger's last "everywhere" computation
  #   (LEDGER_ACCOUNTS). Without this, a brand-new account joining after
  #   the ledger was written makes every already-ledgered session look
  #   "absent" from it and qualifies the whole history for deletion on the
  #   new account's very first sync.
  # - Accounts that exist on disk RIGHT NOW (the live list). Without this,
  #   a ledgered account whose dir disappears entirely (logout, rename,
  #   removal) contributes zero inventory rows, so every session idle since
  #   the last sync looks "absent from a ledgered account" and gets deleted
  #   everywhere: mass data loss from an account-level event, not a
  #   per-session deletion.
  # Only accounts in BOTH sets count toward nacc and absence checks. An
  # empty intersection means nacc=0, so pcount >= nacc always holds and no
  # session can qualify: fail safe. Missing LEDGER_ACCOUNTS (no successful
  # sync yet) is the same empty-set, zero-candidates case.
  : > "$WORK_DIR/ledger_accounts_clean.tsv"
  if [ -f "$LEDGER_ACCOUNTS" ]; then
    cp "$LEDGER_ACCOUNTS" "$WORK_DIR/ledger_accounts_clean.tsv"
  fi

  : > "$WORK_DIR/deletions.tsv"
  : > "$WORK_DIR/kept_by_guard.tsv"
  awk -F'\t' -v OFS='\t' \
      -v LACCTS="$WORK_DIR/ledger_accounts_clean.tsv" -v LIVEACCTS="$WORK_DIR/accounts.tsv" \
      -v LEDGER="$WORK_DIR/ledger_clean.tsv" \
      -v DELFN="$WORK_DIR/deletions.tsv" -v KEPTLOG="$WORK_DIR/kept_by_guard.tsv" '
    BEGIN {
      while ((getline line < LIVEACCTS) > 0) live_acctset[line] = 1
      close(LIVEACCTS)
      nacc = 0
      while ((getline line < LACCTS) > 0) {
        if (line in live_acctset && !(line in ledger_acctset)) {
          ledger_acctset[line] = 1
          nacc++
        }
      }
      close(LACCTS)
      while ((getline line < LEDGER) > 0) {
        split(line, p, "\t")
        ledger_ts[p[1]] = p[2] + 0
        in_ledger[p[1]] = 1
      }
      close(LEDGER)
    }
    {
      f = $1; ts = $2 + 0; acct = $4
      if (!(f in seen)) { order[++n] = f; seen[f] = 1 }
      # The activity guard looks at ALL surviving copies (addendum: "max
      # over ALL surviving copies"), including one in a brand-new account.
      if (!(f in maxts) || ts > maxts[f]) maxts[f] = ts
      # Presence/absence, though, is only judged against the intersection
      # set -- see the comment above this awk block for why.
      if (!(acct in ledger_acctset)) next
      key = f SUBSEP acct
      if (!(key in present)) { present[key] = 1; pcount[f]++ }
    }
    END {
      # Sessions gone from every ledgered account never reach this loop at
      # all (no inv.tsv rows anywhere for that fname); they simply fall out
      # of the ledger rewrite. nacc == 0 (empty intersection) makes the
      # pcount test below always skip: zero candidates, fail safe.
      for (i = 1; i <= n; i++) {
        f = order[i]
        if (!(f in in_ledger)) continue      # never fully synced: never delete
        if (pcount[f] >= nacc) continue      # present in every counted account
        if (maxts[f] > ledger_ts[f]) { print f >> KEPTLOG; continue }
        print f >> DELFN
      }
    }
  ' "$WORK_DIR/inv.tsv"

  if [ -s "$WORK_DIR/kept_by_guard.tsv" ]; then
    while IFS= read -r f; do
      "$emit" "Kept $f everywhere: a surviving copy is newer than the last full sync, so the deletion may predate that activity."
    done < "$WORK_DIR/kept_by_guard.tsv"
  fi

  : > "$WORK_DIR/delete_rows.tsv"
  if [ -s "$WORK_DIR/deletions.tsv" ]; then
    # flags/src are placeholder "-", never empty: bash's `read` with
    # IFS=$'\t' still treats tab as whitespace-class and silently squeezes
    # consecutive-tab (empty-field) runs, which shifts every column after
    # the gap. create/overwrite rows never hit this (their fields are never
    # empty); delete rows have no meaningful flags or src, so use "-".
    awk -F'\t' -v OFS='\t' -v DELFN="$WORK_DIR/deletions.tsv" '
      FILENAME == DELFN { want[$1] = 1; next }
      { if ($1 in want) print "delete", "-", $1, "-", $6, $4, $5 }
    ' "$WORK_DIR/deletions.tsv" "$WORK_DIR/inv.tsv" > "$WORK_DIR/delete_rows.tsv"
  fi
}

update_ledger() {
  # Called at the end of EVERY successful non-dry sync, flag or not (the
  # ledger is what makes a future --sync-deletes run able to tell "deleted"
  # apart from "never synced here yet"). Records fname + winner ts for every
  # session present, after this run's writes, in every account. Reads the
  # post-execute state from disk rather than trusting the pre-run inventory,
  # so a run that only partially completes cannot write a false row.
  # Written atomically (temp file + mv) so a crash mid-write never leaves a
  # truncated ledger; a missing/empty ledger is a normal, safe starting
  # state.
  : > "$WORK_DIR/post_paths.nul"
  for acct in "${accounts[@]}"; do
    for org in "$acct"/*/; do
      [ -d "$org" ] || continue
      for f in "$org"local_*.json; do
        [ -f "$f" ] || continue
        printf '%s\0' "$f" >> "$WORK_DIR/post_paths.nul"
      done
    done
  done

  : > "$WORK_DIR/post_inv.tsv"
  if [ -s "$WORK_DIR/post_paths.nul" ]; then
    xargs -0 awk -v OFS='\t' '
      BEGIN { RS = "\3" }
      FNR == 1 {
        n = split(FILENAME, comp, "/")
        ts = 0
        if (match($0, /"lastActivityAt":[0-9]+/)) {
          t = substr($0, RSTART, RLENGTH)
          sub(/^"lastActivityAt":/, "", t)
          ts = t + 0
        }
        print comp[n], ts, comp[n-2]
      }
    ' < "$WORK_DIR/post_paths.nul" >> "$WORK_DIR/post_inv.tsv"
  fi

  : > "$WORK_DIR/accounts.tsv"
  for a in "${accounts[@]}"; do
    basename "$a" >> "$WORK_DIR/accounts.tsv"
  done

  ledger_tmp="$CANONICAL_DIR/.ledger.tmp.$$"
  mkdir -p "$CANONICAL_DIR"
  awk -F'\t' -v OFS='\t' -v ACCTS="$WORK_DIR/accounts.tsv" '
    BEGIN {
      nacc = 0
      while ((getline line < ACCTS) > 0) nacc++
      close(ACCTS)
    }
    {
      f = $1; ts = $2 + 0; acct = $3
      if (!(f in seen)) { order[++n] = f; seen[f] = 1 }
      key = f SUBSEP acct
      if (!(key in present)) { present[key] = 1; pcount[f]++ }
      if (!(f in maxts) || ts > maxts[f]) maxts[f] = ts
    }
    END {
      for (i = 1; i <= n; i++) {
        f = order[i]
        if (pcount[f] >= nacc) print f, maxts[f]
      }
    }
  ' "$WORK_DIR/post_inv.tsv" > "$ledger_tmp"
  mv "$ledger_tmp" "$LEDGER"

  # Record which accounts this ledger considers "everywhere", so a future
  # --sync-deletes run can tell a brand-new account (not part of this set)
  # apart from an account that genuinely had a ledgered session removed.
  accts_tmp="$CANONICAL_DIR/.ledger-accounts.tmp.$$"
  cp "$WORK_DIR/accounts.tsv" "$accts_tmp"
  mv "$accts_tmp" "$LEDGER_ACCOUNTS"
}

plan_summary() {
  # Honest counts: unique sessions, never file copies (v1 reported one
  # session copied to 12 destinations as "12 synced"). $1 is the emit
  # command (log for real runs, echo for dry runs). Delete rows (verb
  # "delete") only exist when --sync-deletes was on; when the plan has none,
  # every line below is byte-identical to v2.0.0 output.
  emit="$1"
  total_sessions=$(awk 'END { print NR }' "$WORK_DIR/winners.tsv")

  # Per-account one-liners, also session-level. Branch explicitly on verb so
  # "delete" rows are never lumped into "updated" (the old code's implicit
  # else assumed only create/overwrite existed).
  awk -F'\t' '
    {
      ak = $6 SUBSEP $3
      accts[$6] = 1
      if ($1 == "create")      { if (!(ak in cN)) { cN[ak] = 1; accN[$6]++ } }
      else if ($1 == "delete") { if (!(ak in cD)) { cD[ak] = 1; accD[$6]++ } }
      else                     { if (!(ak in cU)) { cU[ak] = 1; accU[$6]++ } }
    }
    END {
      for (a in accts) {
        line = sprintf("  %s: +%d new, %d updated", a, accN[a] + 0, accU[a] + 0)
        if (accD[a] + 0 > 0) line = line sprintf(", -%d deleted", accD[a] + 0)
        print line
      }
    }
  ' "$WORK_DIR/plan.tsv" | sort | while IFS= read -r line; do
    "$emit" "$line"
  done

  counts=$(awk -F'\t' '
    {
      if ($1 == "create")    newf[$3] = 1
      if (index($2, "u"))    upd[$3] = 1
      if (index($2, "a"))    arc[$3] = 1
      if ($1 == "delete")    del[$3] = 1
    }
    END {
      x = 0; for (k in newf) x++
      y = 0; for (k in upd) y++
      z = 0; for (k in arc) z++
      w = 0; for (k in del) w++
      print x, y, z, w
    }
  ' "$WORK_DIR/plan.tsv")
  read -r n_new n_upd n_arc n_del <<< "$counts"

  summary="$n_new new session(s) appeared somewhere, $n_upd session(s) updated to a newer state, $n_arc session(s) archived everywhere (was archived in at least one account)"
  if [ "$n_del" -gt 0 ]; then
    summary="$summary, $n_del session(s) deleted everywhere (deleted in at least one account)"
  fi
  "$emit" "$summary. $total_sessions total sessions across ${#accounts[@]} accounts."
}

execute_plan() {
  # Every write is recorded in the run's manifest; overwrites are backed up
  # first (mirroring <account>/<org>/ so --revert can put them back).
  # cp -p everywhere: plain cp resets mtime, which would make copies look
  # newer than they are on later inspection. The run dir may already exist
  # if the profile layer wrote first; both layers share one manifest.
  ensure_run_dir

  while IFS=$'\t' read -r verb flags fname src dst acct org; do
    if [ "$verb" = "create" ] && [ ! -f "$dst" ]; then
      cp -p "$src" "$dst"
      printf 'created\t%s\n' "$dst" >> "$MANIFEST"
    elif [ "$verb" = "delete" ]; then
      # Only reachable with --sync-deletes. Back up first (same mirrored
      # layout as an overwrite backup), then remove. A dst that vanished
      # between planning and here (already gone) is treated as done.
      if [ -f "$dst" ]; then
        mkdir -p "$RUN_DIR/$acct/$org"
        cp -p "$dst" "$RUN_DIR/$acct/$org/$fname"
        rm -f "$dst"
        printf 'deleted\t%s\t%s\n' "$dst" "$RUN_DIR/$acct/$org/$fname" >> "$MANIFEST"
      fi
    else
      # Overwrite (or a "create" whose destination appeared after the
      # inventory pass): back the current file up first.
      mkdir -p "$RUN_DIR/$acct/$org"
      cp -p "$dst" "$RUN_DIR/$acct/$org/$fname"
      cp -p "$src" "$dst"
      printf 'overwrote\t%s\t%s\n' "$dst" "$RUN_DIR/$acct/$org/$fname" >> "$MANIFEST"
    fi
  done < "$WORK_DIR/plan.tsv"
}

prune_backups() {
  # Keep the newest $BACKUP_KEEP runs. Run dirs are named by epoch (plus a
  # ".reverted" suffix after a revert), so a numeric sort of basenames
  # orders them by age; the names are ours and contain no spaces.
  [ -d "$BACKUPS_DIR" ] || return 0
  old=$(
    for d in "$BACKUPS_DIR"/*/; do
      [ -d "$d" ] && basename "$d"
    done | sort -n | awk -v keep="$BACKUP_KEEP" '
      { a[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print a[i] }'
  )
  for b in $old; do
    rm -rf "$BACKUPS_DIR/$b"
  done
}

do_sync() {
  # Wrapper owning the temp workspace: the watcher calls do_sync in a loop,
  # so cleanup cannot rely on the EXIT trap alone.
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-sync.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$WORK_DIR"' EXIT
  sync_run "$@"
  rc=$?
  rm -rf "$WORK_DIR"
  return $rc
}

sync_run() {
  # $1 = "dry" for --dry-run: full inventory + plan, print every action,
  # write nothing (no backups, no log, no ledger).
  # $2 = "deletes" for --sync-deletes: opt-in deletion propagation. Omitted,
  # behavior (including output) is byte-identical to v2.0.0.
  mode="${1:-}"
  sync_deletes="${2:-}"

  # Profile customization first: fast, and independent of the session
  # machinery (profiles exist even with a single account or no sessions).
  sync_profiles "$mode"

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

  build_inventory
  reduce_winners
  stage_archived

  : > "$WORK_DIR/deletions.tsv"
  : > "$WORK_DIR/delete_rows.tsv"
  if [ "$sync_deletes" = "deletes" ]; then
    if [ "$mode" = "dry" ]; then
      compute_deletions echo
    else
      compute_deletions log
    fi
    if [ -s "$WORK_DIR/deletions.tsv" ]; then
      # Deletion candidates must never be resurrected by this same run:
      # drop them from winners before build_plan ever sees them.
      awk -F'\t' -v OFS='\t' -v DELFN="$WORK_DIR/deletions.tsv" '
        FILENAME == DELFN { drop[$1] = 1; next }
        !($1 in drop)
      ' "$WORK_DIR/deletions.tsv" "$WORK_DIR/winners.tsv" > "$WORK_DIR/winners.filtered.tsv"
      mv "$WORK_DIR/winners.filtered.tsv" "$WORK_DIR/winners.tsv"
    fi
  fi

  build_plan

  if [ -s "$WORK_DIR/delete_rows.tsv" ]; then
    cat "$WORK_DIR/delete_rows.tsv" >> "$WORK_DIR/plan.tsv"
  fi

  if [ ! -s "$WORK_DIR/plan.tsv" ]; then
    total_sessions=$(awk 'END { print NR }' "$WORK_DIR/winners.tsv")
    if [ "$mode" = "dry" ]; then
      echo "Dry run: everything already in sync. $total_sessions total sessions across ${#accounts[@]} accounts."
    else
      log "Everything already in sync. $total_sessions total sessions across ${#accounts[@]} accounts."
      update_ledger
    fi
    return 0
  fi

  if [ "$mode" = "dry" ]; then
    echo "Dry run across ${#accounts[@]} accounts. Planned actions:"
    while IFS=$'\t' read -r verb flags fname src dst acct org; do
      echo "  ${DIM}would $verb:${RESET} $dst"
    done < "$WORK_DIR/plan.tsv"
    plan_summary echo
    echo "${DIM}Nothing was written.${RESET}"
    return 0
  fi

  log "Syncing sessions across ${#accounts[@]} accounts..."
  execute_plan
  prune_backups
  plan_summary log
  update_ledger
  log "Sync complete. Backup: $RUN_DIR ${DIM}(claude-sync --revert undoes this run)${RESET}"
  return 0
}

cmd_revert() {
  # Undo the most recent sync run: delete files it created, restore files
  # it overwrote, then mark the backup dir .reverted so a second --revert
  # targets the run before it.
  [ -d "$BACKUPS_DIR" ] || die "No backups found ($BACKUPS_DIR). Nothing to revert."

  latest=""
  for d in "$BACKUPS_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    case "$name" in *.reverted) continue ;; esac
    [ -f "$d/manifest.tsv" ] || continue
    if [ -z "$latest" ] || [ "$name" -gt "$(basename "$latest")" ]; then
      latest="${d%/}"
    fi
  done
  [ -n "$latest" ] || die "No backup run left to revert."

  log "Reverting sync run $(basename "$latest")..."
  removed=0; restored=0; undeleted=0
  while IFS=$'\t' read -r op path bpath; do
    case "$op" in
      created)
        rm -f "$path"
        removed=$((removed + 1))
        ;;
      overwrote)
        cp -p "$bpath" "$path"
        restored=$((restored + 1))
        ;;
      deleted)
        # The file does not exist at revert time (that is the point of a
        # delete row); a plain copy-back from its backup is correct and
        # needs no existence check, unlike "overwrote".
        cp -p "$bpath" "$path"
        undeleted=$((undeleted + 1))
        ;;
    esac
  done < "$latest/manifest.tsv"

  mv "$latest" "$latest.reverted"
  log "Reverted: removed $removed created file(s), restored $restored overwritten file(s), restored $undeleted deleted file(s)."
  log "${DIM}Backup kept at $latest.reverted. Run --revert again to undo the previous run.${RESET}"
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
  echo "${DIM}To delete the script, log and backups too:${RESET}"
  echo "${DIM}  rm -rf \"$CANONICAL_PATH\" \"$LOG\" \"$BACKUPS_DIR\"${RESET}"
}

# ---------- status / help -------------------------------------------------
cmd_status() {
  echo "claude-sync v$VERSION"
  collect_roots
  if [ ${#roots[@]} -gt 1 ]; then
    echo "Data dirs: ${#roots[@]} (default + $(( ${#roots[@]} - 1 )) profile(s) in 'Claude Profiles')"
    for root in "${roots[@]}"; do
      cfg="$root/claude_desktop_config.json"
      n=0
      if [ -f "$cfg" ]; then
        n=$("$OSASCRIPT" -l JavaScript -e 'function run(a){ObjC.import("Foundation");var s=$.NSString.stringWithContentsOfFileEncodingError($(a[0]),$.NSUTF8StringEncoding,$());if(s.isNil())return 0;try{return Object.keys(JSON.parse(ObjC.unwrap(s)).mcpServers||{}).length}catch(e){return "?"}}' "$cfg" 2>/dev/null)
      fi
      echo "  $(basename "$root"): $n MCP server(s)"
    done
  fi
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
    echo "  ${DIM}_shared (not an account folder, untouched): $(count_index_files "$SESSIONS_DIR/_shared") file(s)${RESET}"
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
  last_sync=""
  if [ -f "$LOG" ]; then
    last_sync=$(grep -F "Sync complete" "$LOG" | tail -1 | sed 's/^\[\([^]]*\)\].*/\1/')
  fi
  echo "Last sync: ${last_sync:-never}"
  runs=0
  for d in "$BACKUPS_DIR"/*/; do
    [ -d "$d" ] && runs=$((runs + 1))
  done
  echo "Backups: $runs stored run(s)"
}

usage() {
  cat <<EOF
claude-sync v$VERSION
Make local Claude Code sessions visible across all Claude Desktop accounts,
and keep customization (MCP servers, Desktop Extensions) in sync across
profiles (claude-deck). Newest session state wins; archived-in-one means
archived-everywhere; overwrites are backed up and revertible. By default
nothing is ever deleted, so a session deleted in one account comes back on
the next sync. Profile sync is additive only: the mcpServers union is added
to every profile's claude_desktop_config.json, default profile wins name
conflicts, logins/cookies/preferences are never touched.

Usage: claude-sync [command]

  (no command)       Run the sync.
  --dry-run          Show what a sync would do, write nothing.
  --sync-deletes     Opt in to deletion propagation: a session fully synced
                     once, then deleted in one account and not touched
                     since, is deleted everywhere. Combine with --dry-run
                     to preview first. Never used by --watch/auto-sync.
  --revert           Undo the most recent sync run from its backup.
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

Warning: --sync-deletes removes files after a backup, but a mistake can
still cost you a session across every account. Run --dry-run --sync-deletes
first and read what it says it would delete.
EOF
}

# ---------- dispatcher ----------------------------------------------------
# --dry-run and --sync-deletes combine in any order; every other command
# stays a single, exact argument (unchanged from v2.0.0).
case "${1:-}" in
  ""|--dry-run|--sync-deletes)
    dry=""; deletes=""
    for arg in "$@"; do
      case "$arg" in
        --dry-run)      dry="dry" ;;
        --sync-deletes) deletes="deletes" ;;
        *)              usage; exit 1 ;;
      esac
    done
    do_sync "$dry" "$deletes"
    exit $?
    ;;
  --revert)          cmd_revert ;;
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
