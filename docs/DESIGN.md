# Design

The full design specification, sanitized for publication. For the build/review history see [RED-TEAM.md](RED-TEAM.md); for a quick mental model see [ARCHITECTURE.md](ARCHITECTURE.md).

## Goal

Mirror Claude Code's auto-memory into an Obsidian vault so you can **see** what Claude remembers — with strict ownership separation and zero risk to the source of truth.

## The four invariants (the laws of the system)

1. **One-way flow.** Data moves `internal memory → vault`, never the reverse. No component ever writes to Claude's memory directory — every sync reads from it only. There is no reverse code path, and none will be added.
2. **The vault is never a source of truth for memory.** If a mirrored file is edited, deleted, or added in the vault, that change is *not* honored — the mirror is restored from internal memory. Restoration is guaranteed at the next session start, and also on any memory write and at session end.
3. **Vault-side drift is recorded before it is erased, and surfaced.** "Drift" means precisely: *the mirror differs from what the system last wrote to it* (manifest-based). Routine forward propagation is **not** drift and is never reported. Real drift's evidence (file names + added/modified/deleted) is appended to a log *before* the restore runs, and surfaced exactly once at session start.
4. **Ownership boundaries.** Claude never writes to the user's zone. The user (by convention) doesn't edit the `Claude/` zone. These are behavioral rules in `CLAUDE.md`, applied to all access paths (file tools and MCP alike).

## Vault layout

```
<vault>/
├─ Claude/
│  ├─ Memory/        ← auto-mirror of internal memory (look-only; managed by this tool)
│  └─ Notes/         ← research/summaries, written only on request
├─ User/             ← your zone — Claude reads, never edits
│  └─ For Claude.md  ← async inbox; injected into Claude's context at session start
└─ Shared/           ← optional; either party may write
```

## Why a hook-driven mirror (alternatives considered)

- **Symlink (rejected):** would make the vault folder *be* the memory — an edit in Obsidian would write straight through to the source of truth, violating invariants 1–2.
- **Convention-only (rejected):** "remember to copy after each memory write" is not deterministic; drift is inevitable.
- **Hook-driven rsync (chosen):** deterministic, one-way, guard-railed, works with Obsidian closed.

## Triggers, guards, manifest

See [ARCHITECTURE.md](ARCHITECTURE.md) for the trigger matrix, the ordered guard list, and the manifest-based drift-detection walkthrough — they are the operational heart of the design and are documented there to avoid duplication.

## Environment assumptions

- **macOS with openrsync** (`/usr/bin/rsync`). The binary is pinned and asserted; exit codes are `0`/`1`/`2` only (no GNU exit-24 path). macOS 14's GNU rsync is correctly refused.
- **BSD `realpath`/`stat`** semantics (e.g. `realpath` fails on a missing leaf — handled by resolving the parent).
- **Local storage** for the vault (not an iCloud dataless-placeholder directory).
- **`python3` present** (used to parse hook JSON and to merge `settings.json`).

Linux support would mean revisiting the rsync pin and the BSD-specific calls; it's tracked as a good-first-issue.

## Error handling

| Situation | Behavior |
|---|---|
| Vault missing/renamed/offline | Hooks exit silently; reconcile on the first sync after it returns |
| Mirror empty/wiped (initialized) | Drift: logged loudly, reported, recreated |
| Memory dir empty / no `MEMORY.md` | Sync refuses (prevents a `--delete` wipe of the mirror) |
| Mirror edited/deleted/added in vault | Evidence logged before restore; reported next session start; restored; never back-propagated |
| Memory changed via shell/external | Caught by session-boundary syncs (no drift report — forward propagation) |
| Session killed before SessionEnd | Changes propagate at next session start — one inter-session gap, accepted |
| `rsync` non-zero exit | Sync aborts, logged, manifest not updated, no retry |

## Out of scope (by design)

Any reverse sync (now or ever); automatic/unsolicited note-writing; filesystem-level permission enforcement of zones (boundaries are behavioral); a background timer (session-boundary triggers bound staleness adequately).
