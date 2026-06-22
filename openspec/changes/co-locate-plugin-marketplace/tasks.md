## 1. plugin def co-located 至 repo 的 `plugin/` 子目錄

實作 spec 需求 **Claude Code plugin definition is co-located in the repo**。

- [ ] 1.1 交付 **Claude Code plugin definition is co-located in the repo**：將 `psychquant-claude-plugins/plugins/che-ical-mcp/` 的 `.claude-plugin/plugin.json`、`.mcp.json`、`bin/che-ical-mcp-wrapper.sh`、`commands/`、`hooks/`、`rules/` 遷入本 repo `plugin/`，逐檔對照無遺漏。驗證：content review 對照遷移前後檔案清單一致。
- [ ] 1.2 依「`references/` vendored 第三方 code 的處置」評估 `references/`：僅納入 plugin 運作必要檔，其餘 gitignore / 不納入（遵 Git 隱私邊界）。驗證：`git status` 確認無非必要第三方 code 進 tracked，repo 體積未暴增。
- [ ] 1.3 確認遷入的 `plugin/bin/che-ical-mcp-wrapper.sh` binary auto-download 邏輯維持不變。驗證：wrapper 在 binary 缺失時下載對應 release binary（手動或 dry-run 驗證）。

## 2. che-ical-mcp 根托管 self-hosted marketplace.json

實作 spec 需求 **che-ical-mcp repo hosts its own Claude Code marketplace**。

- [ ] 2.1 交付 **che-ical-mcp repo hosts its own Claude Code marketplace**：在 repo 根新增 `.claude-plugin/marketplace.json`，含單一 plugin `che-ical-mcp` 條目，`source` 用同 repo 相對路徑 `./plugin`（或 `metadata.pluginRoot` + `source: plugin`）。驗證：marketplace.json 通過結構/schema 檢查（plugin-validator 或 `claude plugin` 驗證）。
- [ ] 2.2 乾淨環境驗證安裝路徑：`/plugin marketplace add kiki830621/che-ical-mcp` → `/plugin install che-ical-mcp@che-ical-mcp` 成功並可呼叫 commands（today/week/remind/quick-event/check-tcc）。驗證：手動安裝 + command 呼叫，記於變更驗證註記。

## 3. 跨 channel 單一版本一致性

實作 spec 需求 **Plugin version is consistent across all distribution artifacts**。

- [ ] 3.1 交付 **Plugin version is consistent across all distribution artifacts**：擴充既有版本一致性機制（#30）涵蓋 `.claude-plugin/marketplace.json` 條目版本與 `plugin/.claude-plugin/plugin.json`，與 `mcpb/manifest.json`、`Version.swift`/`Info.plist` 綁定。驗證：刻意改一處版本使檢查 fail、改回則 pass。

## 4. 文件與聚合器關係

- [ ] 4.1 [P] 更新 `README.md` 安裝路徑為 `/plugin marketplace add kiki830621/che-ical-mcp` → `/plugin install che-ical-mcp@che-ical-mcp`。驗證：README review 含新安裝指令與相對-source 須經 git 加入的限制說明。
- [ ] 4.2 [P] 依「聚合器 psychquant-claude-plugins 的關係調整」撰寫 cross-repo 遷移指引（聚合器條目改 `git-subdir`/`github` 指入本 repo 或移除），文件化於本變更（實作落聚合器 repo，非本 repo）。驗證：遷移指引含具體 marketplace.json source 寫法範例。
