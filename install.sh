#!/bin/bash
# claude-memory-vault installer
# Renders the templates with YOUR machine's real paths baked in as literals, installs the three
# hook scripts into ~/.claude/hooks/, and safely merges the hook registrations into
# ~/.claude/settings.json (never touching hooks that aren't ours).
#
# Usage:
#   ./install.sh                     interactive
#   ./install.sh --vault "PATH" -y   non-interactive with explicit vault path
#   ./install.sh --root "PATH"      (tests only) re-root all targets under a sandbox directory
#
# Why bake paths instead of reading a config at runtime? The mirror's security guards compare
# realpath results against exact literals. A runtime-variable path would weaken exactly the
# property this design was audited for. See docs/DESIGN.md.
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$REPO_DIR/templates"
MARKER_LINE="managed-by: claude-memory-vault"

VAULT_ARG=""
ASSUME_YES=0
ROOT_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT_ARG="${2:?--vault requires a path}"; shift 2 ;;
    -y|--non-interactive) ASSUME_YES=1; shift ;;
    --root) ROOT_OVERRIDE="${2:?--root requires a path}"; shift 2 ;;   # tests only
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

HOME_DIR="${ROOT_OVERRIDE:-$HOME}"
CLAUDE_DIR="$HOME_DIR/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
LOGDIR="$CLAUDE_DIR/logs"
SETTINGS="$CLAUDE_DIR/settings.json"

fail() { echo "✗ $*" >&2; exit 1; }
note() { echo "• $*"; }
ok()   { echo "✓ $*"; }

# ---------- Preflight ----------
[ "$(uname -s)" = "Darwin" ] || fail "macOS only for now — Linux support is tracked in the repo issues."
/usr/bin/rsync --version 2>/dev/null | /usr/bin/grep -q openrsync \
  || fail "/usr/bin/rsync is not openrsync (macOS 14 ships GNU rsync 2.6.9). The scripts pin /usr/bin/rsync for auditable --delete semantics, so a Homebrew rsync is not a substitute. macOS 15+ required."
command -v python3 >/dev/null 2>&1 || fail "python3 is required (preinstalled on supported macOS)."
[ -d "$CLAUDE_DIR" ] || fail "$CLAUDE_DIR not found — is Claude Code installed (and has it run at least once)?"
ok "preflight passed (macOS, openrsync, python3, ~/.claude)"

# ---------- Detect the memory source path ----------
# Claude Code encodes a project path by replacing every non-alphanumeric character with '-'.
HOME_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$HOME_DIR")"
HOME_ENC="$(python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))' "$HOME_REAL")"
SRC_EXPECTED="$CLAUDE_DIR/projects/$HOME_ENC/memory"
SRC_EXPECTED="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SRC_EXPECTED")"

if [ -d "$SRC_EXPECTED" ]; then
  ok "memory source found: $SRC_EXPECTED"
else
  note "memory source not found yet at: $SRC_EXPECTED"
  note "(it appears after Claude Code saves its first auto-memory in your home folder)"
  if [ -d "$CLAUDE_DIR/projects" ]; then
    note "existing project memory dirs:"
    /usr/bin/find "$CLAUDE_DIR/projects" -maxdepth 2 -type d -name memory 2>/dev/null | sed 's/^/    /' || true
  fi
  note "proceeding — the mirror simply does nothing until the memory dir exists."
fi

# ---------- Vault path ----------
DEFAULT_VAULT="$HOME_DIR/Claude Vault"
if [ -n "$VAULT_ARG" ]; then
  VAULT_BASE="$VAULT_ARG"
elif [ "$ASSUME_YES" -eq 1 ]; then
  VAULT_BASE="$DEFAULT_VAULT"
else
  printf "Obsidian vault path [%s]: " "$DEFAULT_VAULT"
  read -r VAULT_BASE
  [ -z "$VAULT_BASE" ] && VAULT_BASE="$DEFAULT_VAULT"
fi
case "$VAULT_BASE" in "~"*) VAULT_BASE="$HOME_DIR${VAULT_BASE#"~"}" ;; esac
VAULT_BASE="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$VAULT_BASE")"
case "$VAULT_BASE" in
  "$CLAUDE_DIR"*) fail "vault path must not live inside ~/.claude/ (it would overlap the source)" ;;
esac
note "vault: $VAULT_BASE"
note "heads-up: the 'Claude/Memory/' subfolder there is fully managed by this tool —"
note "its contents are replaced to exactly match Claude's memory on every sync."

# ---------- Render templates ----------
mkdir -p "$HOOKS_DIR" "$LOGDIR"
render() {  # $1 = template name, $2 = target name
  local tmpl="$TEMPLATES/$1" target="$HOOKS_DIR/$2"
  [ -f "$tmpl" ] || fail "template missing: $tmpl"
  if [ -f "$target" ] && ! /usr/bin/grep -q "$MARKER_LINE" "$target"; then
    cp "$target" "$target.bak"
    note "existing foreign $2 backed up to $2.bak"
  fi
  python3 - "$tmpl" "$target" "$SRC_EXPECTED" "$VAULT_BASE" "$LOGDIR" "$HOOKS_DIR" <<'PY'
import sys
tmpl, target, src, vault, logdir, hooks = sys.argv[1:7]
text = open(tmpl).read()
text = text.replace("@@SRC_EXPECTED@@", src).replace("@@VAULT_BASE@@", vault)
text = text.replace("@@LOGDIR@@", logdir).replace("@@HOOKS_DIR@@", hooks)
assert "@@" not in text, "unrendered token left in " + target
open(target, "w").write(text)
PY
  chmod +x "$target"
  ok "rendered $2"
}
render mirror-memory.sh.tmpl       mirror-memory.sh
render vault-post-write.sh.tmpl    vault-post-write.sh
render vault-session-start.sh.tmpl vault-session-start.sh

# ---------- Merge hooks into settings.json (deep-merge, dedupe, atomic, backed up) ----------
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(/bin/date +%Y%m%d%H%M%S)"
python3 - "$SETTINGS" "$HOOKS_DIR" <<'PY'
import json, sys, os
settings_path, hooks_dir = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    settings = json.load(f)
hooks = settings.setdefault("hooks", {})

def entry(event, command, matcher=None):
    e = {"hooks": [{"type": "command", "command": command}]}
    if matcher: e["matcher"] = matcher
    return e

def has_ours(event_list, basename):
    for e in event_list:
        for h in e.get("hooks", []):
            if basename in h.get("command", ""):
                return True
    return False

wanted = [
    ("SessionStart", os.path.join(hooks_dir, "vault-session-start.sh"), None),
    ("PostToolUse",  os.path.join(hooks_dir, "vault-post-write.sh"), "Write|Edit"),
    ("SessionEnd",   os.path.join(hooks_dir, "mirror-memory.sh") + " sync --quiet", None),
]
changed = False
for event, command, matcher in wanted:
    lst = hooks.setdefault(event, [])
    base = os.path.basename(command.split()[0])
    if not has_ours(lst, base):
        lst.append(entry(event, command, matcher))
        changed = True

tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
json.load(open(tmp))  # validate
os.replace(tmp, settings_path)
print("settings.json: hooks " + ("merged" if changed else "already present (no change)"))
PY
ok "settings.json updated safely (existing hooks preserved; backup kept)"

# ---------- Optional vault scaffold ----------
SCAFFOLD=0
if [ "$ASSUME_YES" -eq 1 ]; then
  SCAFFOLD=1
else
  printf "Create vault zones (Claude/, User/, Shared/ + User/For Claude.md)? [Y/n]: "
  read -r ans
  case "$ans" in n|N) SCAFFOLD=0 ;; *) SCAFFOLD=1 ;; esac
fi
if [ "$SCAFFOLD" -eq 1 ]; then
  mkdir -p "$VAULT_BASE/Claude/Notes" "$VAULT_BASE/User" "$VAULT_BASE/Shared"
  if [ ! -e "$VAULT_BASE/User/For Claude.md" ]; then
    cat > "$VAULT_BASE/User/For Claude.md" <<'EOF'
Anything you write here is read by Claude at the start of every session.
Treat it as a standing inbox — ideas, reminders, requests.
(Heads-up: don't leave anything here you wouldn't want surfaced in any session.)
EOF
  fi
  ok "vault zones ready"
fi

echo ""
ok "install complete"
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code (hooks load at session start)."
echo "  2. Your next session begins with a clean sync — or a MIRROR DRIFT report if anything is off."
echo "  3. See the guarantees exercised: tests/run-tests.sh (runs entirely in /private/tmp sandboxes)."
echo ""
echo "Disclaimer: this tool runs rsync --delete against '<vault>/Claude/Memory/' only, behind"
echo "multiple guards (see docs/DESIGN.md). Review the rendered scripts in $HOOKS_DIR before relying on it."
