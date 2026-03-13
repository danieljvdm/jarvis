---
name: obsidian
description: Search and manage the Obsidian vault synced to /data/vaults via ob. Use for finding notes, reading content, creating/updating notes, and browsing the vault.
allowed-tools: Bash(qmd:*), Bash(cat:*), Bash(find:*), Bash(ls:*), Bash(grep:*), mcp__qmd__*
---

# Obsidian Vault

The vault is synced continuously to `/data/vaults/` using `ob sync --continuous`. Notes are plain markdown files with YAML frontmatter. The QMD search index covers all `.md` files in the vault under the collection name `obsidian`.

## Searching notes

Use the `qmd` skill's query format, scoped to the `obsidian` collection.

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

**MCP (structured):**
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

Results include file paths. Always read the full note after finding a match.

## Reading a note

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
