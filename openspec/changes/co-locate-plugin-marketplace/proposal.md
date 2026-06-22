## Why

che-ical-mcp 的 Claude Code plugin 定義目前住在**另一個 repo**（`psychquant-claude-plugins/plugins/che-ical-mcp/`，38 個 plugin 之一的實體目錄），與本 repo 的 MCP server 原始碼、`mcpb/` Desktop bundle 分離。這條 3-repo 依賴鏈（binary source → marketplace repo → 使用者）造成版本要在多處 bump、`mcpb/manifest.json` 與 `plugin.json` 跨 repo drift（目前靠 #30 的 parity test 硬撐），且聚合器 marketplace 條目（version 1.11.0）已落後 released 1.11.2。

讓 che-ical-mcp repo **自帶自己的 `marketplace.json` 並托管自己的 plugin def**，使單一 repo 成為自足的 distribution unit：MCP server 原始碼 + `mcpb/`（Claude Desktop）+ `plugin/`（Claude Code plugin）+ `.claude-plugin/marketplace.json`（self-hosted marketplace）。使用者可直接 `/plugin marketplace add kiki830621/che-ical-mcp` 安裝，版本只在一處維護。本變更是 38-plugin umbrella 遷移的 **pilot**，建立可被其餘 MCP repo 複用的 pattern。

## What Changes

- **che-ical-mcp 成為 self-hosted marketplace**：在 repo 根新增 `.claude-plugin/marketplace.json`，列出單一 plugin `che-ical-mcp`，`source` 採同 repo 相對路徑（`./plugin`，或以 `metadata.pluginRoot` 簡化）。
- **plugin def co-located 進本 repo**：將 `psychquant-claude-plugins/plugins/che-ical-mcp/` 的 plugin 內容（`.claude-plugin/plugin.json`、`.mcp.json`、`bin/che-ical-mcp-wrapper.sh`、`commands/`、`hooks/`、`rules/`）遷入本 repo `plugin/` 子目錄。`references/`（第三方 vendored code）依 Git 隱私邊界與體積考量評估是否納入或 gitignore。
- **單一版本來源**：`marketplace.json` 條目版本、`plugin/.claude-plugin/plugin.json`、`mcpb/manifest.json`、`Version.swift`/`Info.plist` 以既有 parity 機制（#30）綁定一致。
- **安裝文件更新**：README 記載 `/plugin marketplace add kiki830621/che-ical-mcp` → `/plugin install che-ical-mcp@che-ical-mcp` 的新安裝路徑。
- **聚合器關係（跨 repo，描述於 design）**：`psychquant-claude-plugins` 的 che-ical-mcp 條目改為非實體複本——以 `git-subdir`/`github` source 指向本 repo（消除 divergent 複本），或移除改由本 repo marketplace 取代。此為 cross-repo step，實作落在另一 repo。

## Non-Goals

(空 — 見 design.md 的 Goals / Non-Goals)

## Capabilities

### New Capabilities

- `self-hosted-plugin-marketplace`: che-ical-mcp repo 作為自足的 Claude Code plugin distribution unit —— 托管自己的 `marketplace.json`、co-located 的 plugin def（同 repo 相對 source）、以及跨 distribution channel（marketplace.json / plugin.json / mcpb manifest / Swift version）的單一版本一致性。

### Modified Capabilities

(none)

## Impact

- Affected specs: 新增 `self-hosted-plugin-marketplace`
- Affected code（本 repo）：
  - `.claude-plugin/marketplace.json`（新檔）
  - `plugin/`（新目錄：`.claude-plugin/plugin.json`、`.mcp.json`、`bin/che-ical-mcp-wrapper.sh`、`commands/`、`hooks/`、`rules/`）
  - `README.md`（安裝路徑）
  - 版本一致性檢查（涵蓋新的 marketplace.json + plugin.json）
- Affected code（跨 repo，描述非本 repo 實作）：`psychquant-claude-plugins/.claude-plugin/marketplace.json` 的 che-ical-mcp 條目
- 不影響 runtime MCP 行為、TCC、EventKit。
- 與 `foreground-setup-tcc` 變更正交（後者改 runtime 權限流程，本變更改 distribution 結構）。
