---
name: obsidian
description: Search and manage the Obsidian vault synced to /data/vaults via ob. Use for finding notes, reading content, creating/updating notes, and browsing the vault.
allowed-tools: mcp__qmd__*, Read, Write, Edit, Bash(qmd:*), Bash(cat:*), Bash(find:*), Bash(ls:*), Bash(grep:*)
---

# Obsidian Vault

The vault is synced continuously to `/data/vaults/` using `ob sync --continuous`. Notes are plain markdown files with YAML frontmatter. The QMD search index covers all `.md` files in the vault under the collection name `obsidian`.

## Searching notes

Use the `qmd` skill's query format, scoped to the `obsidian` collection.
Prefer the structured QMD MCP tools when available. Jarvis on Railway may not
have shell `exec`; do not guess paths or create new notes just because shell is
unavailable.

**MCP (preferred):**
```json
{
  "searches": [
    { "type": "lex", "query": "keywords" },
    { "type": "vec", "query": "natural language question" }
  ],
  "collections": ["obsidian"],
  "limit": 10
}
```

**Semantic + keyword (best recall):**
```bash
qmd query $'lex: <keywords>\nvec: <natural language question>' --collection obsidian
```

**Single natural language question (auto-expand):**
```bash
qmd query "what did I write about X?" --collection obsidian
```

**Keyword-only (fast):**
```bash
qmd search "exact term" --collection obsidian
```

Results include file paths. Always read the full note after finding a match.

## Reading a note

Prefer MCP `qmd__get` for search results and the `read` tool for absolute paths.

```bash
cat /data/vaults/<path/to/note>.md
```

Or retrieve by docid from search results:
```bash
qmd get "#abc123"
```

## Listing notes

```bash
# All notes
find /data/vaults -name "*.md" | sort

# Notes in a folder
ls /data/vaults/<folder>/

# Notes with a specific tag (in frontmatter)
grep -rl "tags:.*<tag>" /data/vaults --include="*.md"
```

## Creating or updating a note

Prefer `read` + `edit` for existing notes and `write` only when you are certain
the target note should be new. If a request is about an existing list, search
first; do not create `/data/vaults/<List Name>.md` from a guessed name.

Write standard Obsidian markdown with YAML frontmatter:

```bash
cat > /data/vaults/<path/to/Note>.md << 'EOF'
---
tags: [tag1, tag2]
created: 2025-01-01
---

# Title

Content here.
EOF
```

The `ob sync --continuous` daemon picks up changes and syncs back to Obsidian on other devices automatically.

## Re-indexing after bulk changes

```bash
qmd embed --collection obsidian
```
