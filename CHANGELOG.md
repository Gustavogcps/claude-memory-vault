# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-06-07

First public release.

### Added
- One-way `memory → vault` mirror (`mirror-memory.sh`) with `sync` and `check` modes.
- Manifest-based drift detection: distinguishes routine forward propagation from genuine vault-side changes; logs evidence before restoring; reports each drift exactly once.
- Three Claude Code hooks: `SessionStart` (sync + drift report + inbox injection), `PostToolUse` (low-latency mirror on memory writes), `SessionEnd` (catch deletions).
- `install.sh` / `uninstall.sh`: render templates with your real paths baked in, merge hooks into `settings.json` without clobbering existing hooks, fully reversible.
- 62-check test suite exercising the destructive `rsync --delete` path, every guard with a deterministic trigger, and the installer's settings.json merge/removal safety — all in disposable sandboxes.
- Optional Obsidian MCP integration guide.

### Security / hardening (from five adversarial review rounds; see docs/RED-TEAM.md)
- **Guard 4b** — refuses a symlinked or non-directory mirror root (fixes a critical destination-escape where `rsync --delete` could follow a symlink and destroy data outside the vault).
- Drain-to-archive drift reporting (removes a stale byte-offset that could permanently silence reports).
- PID-liveness lock with a distinct "reconciliation skipped" exit code.
- Guard 6b — TOCTOU re-check closing the snapshot→rsync window.
- openrsync pin with correct exit-code handling (no fictional GNU exit-24 path).
- **Pre-`rsync` TOCTOU re-check** — re-asserts the mirror root is a real directory in the syscalls immediately before the destructive copy, closing the racing variant of the symlink-escape (a post-publication audit finding).
- **Installer hardening** — settings.json hooks are matched by exact command (not basename substring), removal is per-hook so a foreign command sharing an entry block survives, and a malformed/unexpected settings.json now fails loudly instead of reporting false success.
