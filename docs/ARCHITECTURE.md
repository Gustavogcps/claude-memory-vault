# Architecture

One idempotent script, three triggers, a checksum manifest. That's the whole system.

## One script, three triggers

All mirroring runs through **`mirror-memory.sh`** with two modes:

- **`sync [--quiet]`** — guards → drift detection → drift logging → one-way `rsync` → manifest update.
- **`check`** — drift detection only; writes nothing. A manual "is the mirror clean right now?" diagnostic.

Two thin wrappers invoke it from Claude Code hooks:

| Trigger | Hook event | Runs | Purpose |
|---|---|---|---|
| Session start | `SessionStart` | `sync`, then drain the drift report + inject your inbox | **Guaranteed reconciliation point** |
| Memory write | `PostToolUse` (`Write\|Edit`) | `sync` (only if a memory file was touched) | Low-latency mirroring during a session |
| Session end | `SessionEnd` | `sync --quiet` | Catches deletions / shell-driven memory changes |

Why three triggers? `PostToolUse Write|Edit` alone misses file *deletions* and shell-driven changes (there is no Delete tool; memory files are removed via `rm`). The session-boundary syncs make reconciliation guaranteed regardless of *how* memory changed.

```
   Claude Code internal memory                 Your Obsidian vault
   ~/.claude/.../memory/                        <vault>/Claude/Memory/
   ┌─────────────────────┐                      ┌─────────────────────┐
   │ MEMORY.md           │   rsync -a --delete  │ MEMORY.md           │
   │ note-a.md           │ ───────────────────▶ │ note-a.md           │
   │ note-b.md           │     (one way only)   │ note-b.md           │
   └─────────────────────┘                      └─────────────────────┘
            ▲                                              │
            │  ✗ NEVER  (no reverse code path exists)      │ edits here are
            └──────────────────────────────────────────────┘ detected & reverted
```

## Drift detection: the manifest

`rsync` alone can't tell "Claude updated its memory" from "the user edited the vault copy" — both just look like "source and destination differ." A checksum **manifest** resolves it deterministically.

- After every successful sync, the script records `type:sha1:path` for every file in the mirror (the `type` field — `F` file / `L` symlink — means a file swapped for a same-content symlink can't masquerade as unchanged).
- At the start of each sync it recomputes the mirror's current state and compares:
  - **Matches the manifest** → any difference vs. memory is routine forward propagation. Sync silently. *(Everyday path — no alarms.)*
  - **Differs from the manifest** → something *else* changed the mirror. That's drift: classify it (added / modified / deleted in vault), log the evidence **before** restoring, then restore.

Evidence is always written to the log *before* the destructive `rsync` runs, so a restore can never erase its own evidence. The session-start wrapper then surfaces unreported drift to you and moves it to a permanent archive — reported exactly once, no fragile byte-offset bookkeeping.

## The guards (in `mirror-memory.sh`, in order)

1. **Lock** — `mkdir`-based, records owner PID. Dead owners reclaimed immediately; a live owner is never preempted (returns exit `75`, which session-start surfaces as "reconciliation skipped").
2. **Pinned binary** — `/usr/bin/rsync`, asserted to be openrsync. (See [DESIGN.md](DESIGN.md) on why GNU rsync's exit-code 24 doesn't apply here.)
3. **Source guard** — `realpath`-equality to the exact memory path; requires a non-empty `MEMORY.md` (an empty source + `--delete` would wipe the mirror).
4. **Destination guard** — `realpath` the *parent* (BSD `realpath` fails on a missing leaf) + literal `/Memory`, asserted equal to the exact mirror path.
5. **4b — destination-escape guard** — refuses if the `Memory` leaf is a symlink or non-directory. *This is the guard a live red-team added; see [RED-TEAM.md](RED-TEAM.md).*
6. **Drift detection (manifest)** — evidence logged before the destructive step.
7. **6b — TOCTOU guard** — re-checks for files that appear between the drift snapshot and the `rsync`, so a conflict copy can't be erased unobserved.
8. **Exit codes** — only `0` is success (openrsync has no benign-vanish code); the manifest is updated only after a successful sync.

## State files (outside the vault)

`~/.claude/logs/`: `mirror-manifest.txt` (last-written state), `mirror-initialized` (first-run vs lost-manifest marker), `mirror-drift.log` (pending report queue), `mirror-drift.archive.log` (permanent history). Keeping them out of the vault keeps the mirror folder a pure mirror.
