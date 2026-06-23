# Aggregator migration guide (cross-repo follow-up)

This change makes **che-ical-mcp its own self-hosted marketplace** (repo-root
`.claude-plugin/marketplace.json` + co-located `plugin/`). The plugin still *also*
exists as a physical copy in the `psychquant-claude-plugins` aggregator
(`plugins/che-ical-mcp/`). That divergent copy is the drift this change exists to remove.

**This step is cross-repo** — it edits `psychquant-claude-plugins`, NOT che-ical-mcp —
so it is documented here and executed there as a follow-up. Until it runs, both entries
coexist (acceptable for the pilot; the aggregator copy was synced to the same version).

## Option A — point the aggregator entry at this repo via `git-subdir` (recommended)

Replace the aggregator's physical `source: "./plugins/che-ical-mcp"` with a sparse-clone
reference to this repo's `plugin/` subdirectory, pinned to a release tag. Single source of
truth; no physical copy to drift.

In `psychquant-claude-plugins/.claude-plugin/marketplace.json`, the che-ical-mcp entry's
`source` becomes:

```json
"source": {
  "source": "git-subdir",
  "url": "PsychQuant/che-ical-mcp",
  "path": "plugin",
  "ref": "v1.12.0"
}
```

Then delete `psychquant-claude-plugins/plugins/che-ical-mcp/` (the physical copy), commit,
push, and `claude plugin marketplace update psychquant-claude-plugins`. Bump `ref` each
release (or pin `sha` for an exact commit).

## Option B — point at the whole repo via `github`

Only viable if a plugin manifest sits at the repo root; che-ical-mcp keeps its manifest
under `plugin/`, so `github` (whole-repo) does **not** apply here. Listed for completeness;
prefer Option A.

```json
"source": { "source": "github", "repo": "PsychQuant/che-ical-mcp", "ref": "v1.12.0" }
```

## Option C — remove the aggregator entry entirely

If the self-hosted marketplace (`claude plugin marketplace add PsychQuant/che-ical-mcp`)
fully replaces aggregator distribution, delete the che-ical-mcp entry from the aggregator's
`marketplace.json` and remove `plugins/che-ical-mcp/`. Existing aggregator-installed users
must re-add the new marketplace; communicate before doing this.

## Recommendation

Option A. It keeps the aggregator as a discovery surface while eliminating the divergent
physical copy — existing `che-ical-mcp@psychquant-claude-plugins` install paths keep working,
and the version is pinned to this repo's release tag (no more multi-repo version bumps).

## Relationship to the umbrella rollout

This change is the **pilot** (che-ical-mcp only). The other che-* MCP repos each get their
own `self-hosted-plugin-marketplace` change following this same pattern; this guide is the
template for their aggregator-entry migration.
