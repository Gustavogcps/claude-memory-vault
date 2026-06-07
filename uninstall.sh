#!/bin/bash
# claude-memory-vault uninstaller
# Removes ONLY this tool's hook registrations from ~/.claude/settings.json and the three rendered
# scripts from ~/.claude/hooks/. It does NOT touch your vault, Claude's memory, or the logs/manifest
# (their locations are printed so you can clean them manually if you want). Idempotent.
#
# Usage: ./uninstall.sh            |  ./uninstall.sh --root "PATH"  (tests only)
set -u

ROOT_OVERRIDE=""
[ "${1:-}" = "--root" ] && ROOT_OVERRIDE="${2:?--root requires a path}"
HOME_DIR="${ROOT_OVERRIDE:-$HOME}"
CLAUDE_DIR="$HOME_DIR/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
MARKER_LINE="managed-by: claude-memory-vault"

ok() { echo "✓ $*"; }

# ---------- Remove our entries from settings.json ----------
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(/bin/date +%Y%m%d%H%M%S)"
  python3 - "$SETTINGS" "$HOOKS_DIR" <<'PY' || { echo "✗ settings.json parse failed — left unchanged (backup kept)" >&2; exit 1; }
import json, sys, os
settings_path, hooks_dir = sys.argv[1], sys.argv[2]
try:
    with open(settings_path, encoding="utf-8-sig") as f:
        settings = json.load(f)
except Exception as e:
    sys.exit("could not parse %s: %s" % (settings_path, e))
if not isinstance(settings, dict):
    sys.exit("settings.json is not a JSON object")
hooks = settings.get("hooks", {})
if not isinstance(hooks, dict):
    sys.exit("settings.json 'hooks' is not an object")

# Our hooks are identified by EXACT command match, anchored to this install's hooks_dir, so a
# foreign command that merely contains our script name (or a sibling of the same name elsewhere)
# is never touched.
OURS = {
    os.path.join(hooks_dir, "vault-session-start.sh"),
    os.path.join(hooks_dir, "vault-post-write.sh"),
    os.path.join(hooks_dir, "mirror-memory.sh") + " sync --quiet",
}

removed = 0
for event in list(hooks.keys()):
    if not isinstance(hooks[event], list):
        continue
    kept_entries = []
    for e in hooks[event]:
        if not isinstance(e, dict):
            kept_entries.append(e); continue
        # Filter at the per-COMMAND level: drop only our hook objects, keep foreign siblings
        # that happen to share the same entry block.
        kept_hooks = []
        for h in e.get("hooks", []):
            if isinstance(h, dict) and h.get("command", "") in OURS:
                removed += 1
            else:
                kept_hooks.append(h)
        if kept_hooks:
            e["hooks"] = kept_hooks
            kept_entries.append(e)
        # else: the block held only our hook(s) → drop the now-empty block
    if kept_entries:
        hooks[event] = kept_entries
    else:
        del hooks[event]
if not hooks and "hooks" in settings:
    del settings["hooks"]

tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
json.load(open(tmp))
os.replace(tmp, settings_path)
print("settings.json: removed %d claude-memory-vault hook %s" % (removed, "entry" if removed == 1 else "entries"))
PY
  ok "settings.json cleaned (backup kept; foreign hooks untouched)"
fi

# ---------- Remove our rendered scripts (only if they carry our marker); restore any foreign .bak ----------
for s in mirror-memory.sh vault-post-write.sh vault-session-start.sh; do
  t="$HOOKS_DIR/$s"
  if [ -f "$t" ] && /usr/bin/grep -q "$MARKER_LINE" "$t"; then
    rm "$t"
    ok "removed $s"
    if [ -f "$t.bak" ]; then
      mv "$t.bak" "$t"
      ok "restored your previous $s from $s.bak"
    fi
  fi
done

echo ""
ok "uninstall complete — your vault and Claude's memory were not touched."
echo "Left in place (delete manually if you wish):"
echo "  $CLAUDE_DIR/logs/mirror-manifest.txt, mirror-initialized, mirror-drift.log, mirror-drift.archive.log"
echo "  your vault's Claude/Memory/ folder (it's just files; safe to keep or delete)"
