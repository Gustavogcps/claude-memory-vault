#!/bin/bash
# claude-memory-vault — self-contained test suite.
# Renders the templates into disposable /private/tmp sandboxes (the same render path install.sh
# uses) and exercises every guard, including the destructive rsync --delete logic, against
# throwaway data. Never touches your real vault, memory, or settings. Exit 1 if any test fails.
#
# Usage: tests/run-tests.sh
set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES="$REPO_DIR/templates"
. "$REPO_DIR/tests/lib/assert.sh"

# /private/tmp is canonical (/tmp is a symlink — the realpath guards would reject it, by design).
SANDBOX_BASE="/private/tmp/cmv-tests.$$"
rm -rf "$SANDBOX_BASE"
trap 'rm -rf "$SANDBOX_BASE"' EXIT

# Render one template with sandbox literals baked in (mirrors install.sh's python replace).
render() {  # $1 tmpl, $2 target, SRC VAULT LOG HOOKS via env
  python3 - "$TEMPLATES/$1" "$2" "$SRC" "$VAULT" "$LOG" "$HOOKS" <<'PY'
import sys
tmpl, target, src, vault, log, hooks = sys.argv[1:7]
t = open(tmpl).read()
t = t.replace("@@SRC_EXPECTED@@", src).replace("@@VAULT_BASE@@", vault)
t = t.replace("@@LOGDIR@@", log).replace("@@HOOKS_DIR@@", hooks)
assert "@@" not in t, "unrendered token"
open(target, "w").write(t)
PY
  chmod +x "$2"
}

# Build a fresh sandbox; returns with SRC/VAULT/LOG/HOOKS + a baseline MEMORY.md.
fresh_sandbox() {
  local d="$SANDBOX_BASE/$1"; rm -rf "$d"
  mkdir -p "$d/memory" "$d/Claude Vault/Claude" "$d/logs" "$d/hooks"
  SRC="$(/bin/realpath "$d/memory")"
  VAULT="$(/bin/realpath "$d/Claude Vault")"
  LOG="$(/bin/realpath "$d/logs")"
  HOOKS="$(/bin/realpath "$d/hooks")"
  printf '# Index\n- test\n' > "$SRC/MEMORY.md"
  render mirror-memory.sh.tmpl       "$HOOKS/mirror-memory.sh"
  render vault-post-write.sh.tmpl    "$HOOKS/vault-post-write.sh"
  render vault-session-start.sh.tmpl "$HOOKS/vault-session-start.sh"
  MIRROR="$HOOKS/mirror-memory.sh"
  P="$VAULT/Claude/Memory"
}

echo "claude-memory-vault test suite"
echo "sandbox: $SANDBOX_BASE"
echo ""

# ── 1. First sync creates mirror, manifest, marker; no drift ──
echo "[1] first sync"
fresh_sandbox t1
printf 'fact one\n' > "$SRC/note-a.md"
printf 'fact two\n' > "$SRC/note with spaces.md"
out="$("$MIRROR" sync)"; assert_contains "$out" "mirror synced" "first sync reports synced"
assert_file_exists "$P/MEMORY.md" "MEMORY.md mirrored"
assert_file_exists "$P/note with spaces.md" "filename with spaces mirrored"
assert_eq "$(wc -l < "$LOG/mirror-manifest.txt" | tr -d ' ')" "3" "manifest has 3 entries"
assert_file_exists "$LOG/mirror-initialized" "init marker dropped"
assert_file_absent "$LOG/mirror-drift.log" "no drift log on clean first run"

# ── 2. Forward deletion in memory propagates silently (no drift) ──
echo "[2] forward deletion is silent"
rm "$SRC/note-a.md"
out="$("$MIRROR" sync)"; assert_contains "$out" "mirror synced" "sync after delete"
assert_file_absent "$P/note-a.md" "deletion propagated to mirror"
assert_file_absent "$LOG/mirror-drift.log" "forward deletion logged NO drift"

# ── 3. Vault-side edit + delete + add are each detected, classified, restored ──
echo "[3] vault-side tamper detected & restored"
echo "TAMPERED" >> "$P/MEMORY.md"
rm "$P/note with spaces.md"
echo intruder > "$P/new-vault-file.md"
out="$("$MIRROR" sync)"; assert_contains "$out" "mirror restored" "sync restores on drift"
assert_log_contains "$LOG/mirror-drift.log" "modified in vault: ./MEMORY.md" "edit classified as modified"
assert_log_contains "$LOG/mirror-drift.log" "deleted in vault: ./note with spaces.md" "delete classified"
assert_log_contains "$LOG/mirror-drift.log" "added in vault: ./new-vault-file.md" "add classified"
assert_not_contains "$(cat "$P/MEMORY.md")" "TAMPERED" "edit reverted"
assert_file_exists "$P/note with spaces.md" "deleted file restored"
assert_file_absent "$P/new-vault-file.md" "added file removed"
# one-way proof: source MEMORY.md never gained TAMPERED
assert_not_contains "$(cat "$SRC/MEMORY.md")" "TAMPERED" "INTERNAL MEMORY untouched (one-way)"

# ── 4. CRITICAL: symlinked Memory leaf is refused, not followed (destination escape) ──
echo "[4] CRITICAL symlinked-destination escape is refused"
fresh_sandbox t4
"$MIRROR" sync --quiet
OUTSIDE="$SANDBOX_BASE/t4-outside"; mkdir -p "$OUTSIDE"
printf 'PRECIOUS\n' > "$OUTSIDE/userA.txt"
rm -rf "$P"; ln -s "$OUTSIDE" "$P"
"$MIRROR" sync >/dev/null 2>&1; rc=$?
assert_exit "$rc" "1" "sync refuses symlinked mirror root"
assert_file_exists "$OUTSIDE/userA.txt" "data OUTSIDE the vault is intact (not followed by --delete)"
assert_contains "$(cat "$OUTSIDE/userA.txt")" "PRECIOUS" "outside data unchanged"
assert_log_contains "$LOG/mirror-drift.log" "symlink — refusing" "symlink refusal logged"

# ── 5. Empty source / missing MEMORY.md refuses (protects mirror from --delete wipe) ──
echo "[5] empty-source refusal"
fresh_sandbox t5
"$MIRROR" sync --quiet
mv "$SRC/MEMORY.md" "$SANDBOX_BASE/stash.md"
out="$("$MIRROR" sync)"; assert_contains "$out" "refusing to sync" "missing MEMORY.md refuses"
assert_file_exists "$P/MEMORY.md" "mirror NOT wiped by empty source"

# ── 6. Wiped mirror dir (deleted entirely) recovers + logs loudly ──
echo "[6] wiped mirror recreated"
fresh_sandbox t6
"$MIRROR" sync --quiet
rm -rf "$P"
"$MIRROR" sync >/dev/null
assert_file_exists "$P/MEMORY.md" "wiped mirror recreated"
assert_log_contains "$LOG/mirror-drift.log" "missing or empty" "wipe logged as drift"

# ── 7. Lost manifest with marker present = drift of unknown extent ──
echo "[7] lost manifest"
fresh_sandbox t7
"$MIRROR" sync --quiet
rm "$LOG/mirror-manifest.txt"
"$MIRROR" sync >/dev/null
assert_log_contains "$LOG/mirror-drift.log" "unknown extent" "lost manifest flagged"

# ── 8. Vault absent => silent no-op exit 0 ──
echo "[8] vault absent tolerated"
fresh_sandbox t8
"$MIRROR" sync --quiet
mv "$VAULT" "$VAULT.away"
"$MIRROR" sync >/dev/null 2>&1; assert_exit "$?" "0" "vault absent exits 0 silently"
mv "$VAULT.away" "$VAULT"

# ── 9. rsync failure (immutable dest) aborts, manifest untouched, recovers ──
echo "[9] rsync failure path"
fresh_sandbox t9
"$MIRROR" sync --quiet
m1="$(shasum "$LOG/mirror-manifest.txt" | awk '{print $1}')"
chflags uchg "$P"
printf 'newfile\n' > "$SRC/note-b.md"
"$MIRROR" sync >/dev/null 2>&1; assert_exit "$?" "1" "rsync failure aborts with exit 1"
m2="$(shasum "$LOG/mirror-manifest.txt" | awk '{print $1}')"
assert_eq "$m1" "$m2" "manifest NOT updated on failure"
assert_log_contains "$LOG/mirror-drift.log" "ERROR rsync exit" "failure logged"
chflags nouchg "$P"
"$MIRROR" sync >/dev/null; assert_file_exists "$P/note-b.md" "recovers after fault cleared"

# ── 10. Concurrency: live lock exits 75; dead-PID lock reclaimed ──
echo "[10] lock handling"
fresh_sandbox t10
"$MIRROR" sync --quiet
sleep 30 & livepid=$!
mkdir "$LOG/mirror.lock"; echo "$livepid" > "$LOG/mirror.lock/pid"
"$MIRROR" sync >/dev/null 2>&1; assert_exit "$?" "75" "live lock => exit 75 (skip)"
kill "$livepid" 2>/dev/null
echo "999999" > "$LOG/mirror.lock/pid"
"$MIRROR" sync >/dev/null 2>&1; assert_exit "$?" "0" "dead-PID lock reclaimed"
rm -rf "$LOG/mirror.lock"

# ── 11. check mode: detects drift, writes nothing ──
echo "[11] check mode writes nothing"
fresh_sandbox t11
"$MIRROR" sync --quiet
l1="$(stat -f %z "$LOG/mirror-drift.log" 2>/dev/null || echo 0)"
mm1="$(shasum "$LOG/mirror-manifest.txt" | awk '{print $1}')"
out="$("$MIRROR" check)"; assert_contains "$out" "mirror clean" "check reports clean"
l2="$(stat -f %z "$LOG/mirror-drift.log" 2>/dev/null || echo 0)"
mm2="$(shasum "$LOG/mirror-manifest.txt" | awk '{print $1}')"
assert_eq "$l1" "$l2" "check wrote no drift log"
assert_eq "$mm1" "$mm2" "check did not touch manifest"
echo "DIRTY" >> "$P/MEMORY.md"
"$MIRROR" check >/dev/null 2>&1; assert_exit "$?" "1" "check exits 1 on dirty mirror"
assert_not_contains "$(cat "$SRC/MEMORY.md")" "DIRTY" "check did not restore/alter source"

# ── 12. Session-start drains drift report once, then silent; inbox injected ──
echo "[12] session-start report drain + inbox"
fresh_sandbox t12
mkdir -p "$VAULT/User"
echo "REMEMBER-THE-MILK" > "$VAULT/User/For Claude.md"
"$MIRROR" sync --quiet
echo "TAMP" >> "$P/MEMORY.md"
a="$("$HOOKS/vault-session-start.sh")"
assert_contains "$a" "MIRROR DRIFT REPORT" "session A surfaces drift"
assert_contains "$a" "REMEMBER-THE-MILK" "inbox injected"
b="$("$HOOKS/vault-session-start.sh")"
assert_not_contains "$b" "MIRROR DRIFT REPORT" "session B does not re-report (drained)"
assert_contains "$b" "REMEMBER-THE-MILK" "inbox still injected every session"
assert_log_contains "$LOG/mirror-drift.archive.log" "modified in vault" "drift archived permanently"

# ── 13. Guard 2: refuses a non-openrsync binary (negative test) ──
echo "[13] openrsync guard refuses GNU rsync"
fresh_sandbox t13
"$MIRROR" sync --quiet
# stub binary that mimics GNU rsync's version banner (no 'openrsync' token)
STUB="$SANDBOX_BASE/fakersync"; printf '#!/bin/bash\necho "rsync  version 2.6.9  protocol version 29"\n' > "$STUB"; chmod +x "$STUB"
sed "s#^RSYNC=\"/usr/bin/rsync\"#RSYNC=\"$STUB\"#" "$MIRROR" > "$HOOKS/mirror-stub.sh"; chmod +x "$HOOKS/mirror-stub.sh"
"$HOOKS/mirror-stub.sh" sync >/dev/null 2>&1; assert_exit "$?" "1" "non-openrsync binary refused"
assert_log_contains "$LOG/mirror-drift.log" "is not openrsync" "openrsync refusal logged"

# ── 14. install.sh merges hooks WITHOUT clobbering foreign hooks; idempotent ──
echo "[14] settings.json merge preserves foreign hooks"
IROOT="$SANDBOX_BASE/installroot"
mkdir -p "$IROOT/.claude"
cat > "$IROOT/.claude/settings.json" <<'EOF'
{
  "theme": "dark",
  "hooks": {
    "PostToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "/some/foreign/hook.sh" }] }
    ]
  }
}
EOF
"$REPO_DIR/install.sh" --root "$IROOT" --vault "$IROOT/Vault" -y >/dev/null 2>&1
merged="$(cat "$IROOT/.claude/settings.json")"
assert_contains "$merged" "/some/foreign/hook.sh" "foreign Bash hook preserved"
assert_contains "$merged" "vault-post-write.sh" "our PostToolUse hook added"
assert_contains "$merged" "vault-session-start.sh" "our SessionStart hook added"
assert_contains "$merged" "\"theme\": \"dark\"" "unrelated settings preserved"
# idempotency: second run does not duplicate
"$REPO_DIR/install.sh" --root "$IROOT" --vault "$IROOT/Vault" -y >/dev/null 2>&1
cnt="$(/usr/bin/grep -c "vault-post-write.sh" "$IROOT/.claude/settings.json")"
assert_eq "$cnt" "1" "re-running install does not duplicate hooks"
python3 -m json.tool "$IROOT/.claude/settings.json" >/dev/null 2>&1; assert_exit "$?" "0" "settings.json stays valid JSON"

# ── 15. uninstall removes only ours; foreign hook survives ──
echo "[15] uninstall removes only our hooks"
"$REPO_DIR/uninstall.sh" --root "$IROOT" >/dev/null 2>&1
after="$(cat "$IROOT/.claude/settings.json")"
assert_contains "$after" "/some/foreign/hook.sh" "foreign hook survives uninstall"
assert_not_contains "$after" "vault-post-write.sh" "our hook removed by uninstall"

summary
