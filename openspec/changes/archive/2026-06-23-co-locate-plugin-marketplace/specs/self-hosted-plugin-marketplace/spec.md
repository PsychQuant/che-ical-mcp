## ADDED Requirements

### Requirement: che-ical-mcp repo hosts its own Claude Code marketplace

The che-ical-mcp repository SHALL contain a `.claude-plugin/marketplace.json` at its root that defines a marketplace listing the `che-ical-mcp` plugin. Adding the repository as a marketplace via git SHALL make the plugin discoverable and installable without depending on any external aggregator repository.

#### Scenario: User adds the repo as a marketplace and installs the plugin

- **WHEN** a user runs `/plugin marketplace add kiki830621/che-ical-mcp`
- **THEN** Claude Code loads the marketplace from the repo root `.claude-plugin/marketplace.json`
- **AND** the marketplace lists a plugin named `che-ical-mcp`
- **AND** running `/plugin install che-ical-mcp@che-ical-mcp` installs the plugin

#### Scenario: Marketplace entry resolves the co-located plugin via same-repo source

- **WHEN** the marketplace entry's `source` is a same-repo relative path to the co-located plugin directory
- **THEN** the plugin is fetched from within the same repository when the marketplace is added via git
- **AND** no physical copy of the plugin in an external aggregator repository is required for installation

### Requirement: Claude Code plugin definition is co-located in the repo

The che-ical-mcp repository SHALL contain the full Claude Code plugin definition in a dedicated `plugin/` subdirectory, including the plugin manifest, MCP server wiring, binary wrapper, commands, hooks, and rules, so the repository is a self-contained distribution unit for the Claude Code channel.

#### Scenario: Installed plugin exposes the expected commands and wiring

- **WHEN** the `che-ical-mcp` plugin is installed from the co-located definition
- **THEN** the plugin manifest (`plugin/.claude-plugin/plugin.json`), MCP config (`plugin/.mcp.json`), and binary wrapper (`plugin/bin/che-ical-mcp-wrapper.sh`) are present
- **AND** the plugin's commands, hooks, and rules behave identically to the prior aggregator-hosted definition

#### Scenario: Wrapper still auto-downloads the release binary

- **WHEN** the installed plugin's wrapper runs and the expected binary is absent
- **THEN** the wrapper downloads the matching release binary as it did under the aggregator-hosted definition

### Requirement: Plugin version is consistent across all distribution artifacts

The plugin version recorded in `.claude-plugin/marketplace.json`, `plugin/.claude-plugin/plugin.json`, `mcpb/manifest.json`, and the Swift version source SHALL be consistent. A consistency check SHALL fail the build or release when any of these versions diverge.

#### Scenario: Divergent versions fail the consistency check

- **WHEN** the version in `.claude-plugin/marketplace.json` differs from `plugin/.claude-plugin/plugin.json` or `mcpb/manifest.json`
- **THEN** the version consistency check fails

##### Example: version sources that MUST match

| Artifact | Version field |
| -------- | ------------- |
| `.claude-plugin/marketplace.json` | plugin entry `version` |
| `plugin/.claude-plugin/plugin.json` | `version` |
| `mcpb/manifest.json` | `version` |
| Swift version source / `Info.plist` | `CFBundleShortVersionString` |
