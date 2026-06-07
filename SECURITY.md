# Security Policy

## Reporting a vulnerability

Please report security issues **privately** via GitHub's [private vulnerability reporting](https://github.com/Gustavogcps/claude-memory-vault/security/advisories/new) (Security tab → Report a vulnerability) rather than a public issue. You'll get a response as quickly as I can manage. Once a fix is available, the finding will be credited in the changelog unless you prefer otherwise.

## Scope

This tool runs `rsync -a --delete` against the `Claude/Memory/` folder inside your configured vault path. Findings of particular interest:

- Any code path that could write to or delete files in the **memory source** directory (invariant #1 — must never happen).
- Any way to make `rsync --delete` affect a path **outside** `<vault>/Claude/Memory/` (this is exactly the class of bug a red-team found pre-release — see [docs/RED-TEAM.md](docs/RED-TEAM.md); guard 4b addresses the known case).
- Any way to make genuine vault-side drift go **unreported** while being silently overwritten.

## What is *not* a vulnerability here

- The optional Obsidian MCP server granting full vault access — that's a property of the third-party plugin, documented in [docs/OBSIDIAN-MCP.md](docs/OBSIDIAN-MCP.md), and the boundary is behavioral by design.
- The vault state files in `~/.claude/logs/` being writable by anything that can write your home dir — that directory is a trust boundary; an attacker with write access there can already do worse.

## Disclaimer

Provided "AS IS" without warranty (see [LICENSE](LICENSE)). Review the rendered scripts before relying on the tool.
