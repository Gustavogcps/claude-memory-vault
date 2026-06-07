# Optional: Obsidian app control via MCP

The mirror itself works with Obsidian open or closed — it's just files. But if you want Claude Code to *drive* Obsidian (open notes in the UI, use Obsidian's search index, run commands), you can add the Obsidian MCP server. This is entirely optional and **uses no code from this project** — it's a community plugin plus one `claude mcp add` command.

## Setup

1. In Obsidian: **Settings → Community plugins → Browse →** search **"Local REST API"** → Install → Enable.
2. Confirm it's **v4.1.3 or newer** (earlier 4.x had a path-traversal fix you want).
3. Open **Settings → Local REST API**. Optionally enable **"Non-encrypted (HTTP) Server"** to avoid self-signed-cert friction (it stays localhost-only either way).
4. Copy the **API key** shown on that settings page.
5. Register it with Claude Code:

   ```bash
   claude mcp add --scope user --transport http obsidian \
     http://127.0.0.1:27123/mcp/ \
     --header "Authorization: Bearer YOUR_API_KEY_HERE"
   ```

6. Restart Claude Code. The `obsidian` tools load at session start.

## Security notes

- **Generate your own key. Never commit it** to any repo or leave it in a file that syncs (Obsidian Sync / iCloud). It belongs only in Claude Code's config (`~/.claude.json`).
- The endpoint is **localhost-only** (`127.0.0.1`). The HTTPS port (`27124`) uses a self-signed cert; the HTTP port (`27123`) avoids that — both stay on your machine.
- This server grants **full vault read/write** with no path scoping. The ownership boundary (don't let the model write to your zone or to `Claude/Memory/`) is then a *behavioral* rule, not an enforced one. If you want it enforced, use a server with path ACLs (e.g. `cyanheads/obsidian-mcp-server`, which supports `OBSIDIAN_READ_PATHS` / `OBSIDIAN_WRITE_PATHS`).

## Why it's not in the critical path

The memory mirror never depends on MCP. If the plugin is off, the app is closed, or the key is invalid, the mirror, drift detection, and inbox all keep working. MCP is purely additive.
