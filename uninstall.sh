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
  python3 - "$SETTINGS" <<'PY'
import json, sys, os
settings_path = sys.argv[1]
with open(settings_path) as f:
    settings = json.load(f)
hooks = settings.get("hooks", {})
OURS = ("vault-session-start.sh", "vault-post-write.sh", "mirror-memory.sh")

removed = 0
for event in list(hooks.keys()):
    kept = []
    for e in hooks[event]:
        cmds = [h.get("command", "") for h in e.get("hooks", [])]
        if any(any(o in c for o in OURS) for c in cmds):
            removed += 1
        else:
            kept.append(e)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if not hooks and "hooks" in settings:
    del settings["hooks"]

tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
json.load(open(tmp))
os.replace(tmp, settings_path)
print(f"settings.json: removed {removed} claude-memory-vault hook entr{'y' if removed==1 else 'ies'}")
PY
  ok "settings.json cleaned (backup kept; foreign hooks untouched)"
fi

# ---------- Remove our rendered scripts (only if they carry our marker) ----------
for s in mirror-memory.sh vault-post-write.sh vault-session-start.sh; do
  t="$HOOKS_DIR/$s"
  if [ -f "$t" ] && /usr/bin/grep -q "$MARKER_LINE" "$t"; then
    rm "$t"
    ok "removed $s"
  fi
done

echo ""
ok "uninstall complete — your vault and Claude's memory were not touched."
echo "Left in place (delete manually if you wish):"
echo "  $CLAUDE_DIR/logs/mirror-manifest.txt, mirror-initialized, mirror-drift.log, mirror-drift.archive.log"
echo "  your vault's Claude/Memory/ folder (it's just files; safe to keep or delete)"
