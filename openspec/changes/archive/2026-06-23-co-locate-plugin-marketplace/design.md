## Context

che-ical-mcp 目前透過兩條獨立 distribution channel 發佈：
- **Claude Desktop**：本 repo `mcpb/` 內的 `.mcpb` bundle（`manifest.json` + `server/CheICalMCP`）。
- **Claude Code**：`psychquant-claude-plugins` repo `plugins/che-ical-mcp/` 的 plugin def（`.claude-plugin/plugin.json`、`.mcp.json`、wrapper、commands、hooks、rules），由該 repo 的 `marketplace.json` 以 `source: ./plugins/che-ical-mcp` 列出。該聚合器共 38 個 plugin、全為實體目錄、無 submodule。

官方文檔（code.claude.com/docs/en/plugin-marketplaces）確認 plugin `source` 支援：相對路徑 `./x`（同 repo、git 加入時可解析）、`github`（`{repo,ref}`）、`url`、`git-subdir`（`{url,path,ref?,sha?}` sparse clone 子目錄）、`npm`。一個 git repo 只要根有 `.claude-plugin/marketplace.json` 即為 marketplace，且可同時於同 repo 托管 plugin（walkthrough 範例即如此）。

使用者選定方向：**che-ical-mcp repo 直接作為它自己的 marketplace**，plugin def co-located 於同 repo。範圍為 pilot（僅本 repo），其餘 MCP repo 的遷移為各自 follow-up。

## Goals / Non-Goals

**Goals:**

- che-ical-mcp repo 自足：單一 repo 同時是 marketplace、托管 plugin def、含 MCP server 原始碼與 `mcpb/` Desktop bundle。
- 使用者可 `/plugin marketplace add kiki830621/che-ical-mcp` → `/plugin install che-ical-mcp@che-ical-mcp` 安裝。
- plugin 版本與 manifest 單一來源、跨 channel 一致（marketplace.json / plugin.json / mcpb manifest / Swift version）。
- 建立可被其餘 MCP repo 複用的 self-hosted-marketplace pattern。

**Non-Goals:**

- **不在本變更遷移其餘 37 個 plugin**：各 repo 自己的 follow-up change。
- **不改 runtime MCP / TCC / EventKit 行為**：與 `foreground-setup-tcc` 正交。
- **不採 `github` whole-repo source**：要求 plugin manifest 在 repo 根，與 Swift package 結構衝突。
- **不在本 repo 直接編輯聚合器 repo 的檔案**：聚合器條目調整為 cross-repo step，描述於此但實作於 `psychquant-claude-plugins`。

## Decisions

### che-ical-mcp 根托管 self-hosted marketplace.json

在 repo 根新增 `.claude-plugin/marketplace.json`，含單一 plugin 條目 `che-ical-mcp`，`source` 用同 repo 相對路徑指向 co-located plugin def。相對 source 在使用者經 git 加入 marketplace 時可正確解析（文檔明載），符合 `/plugin marketplace add kiki830621/che-ical-mcp` 的使用情境。

*替代方案*：`git-subdir` 由外部聚合器指入——仍可作為聚合器側的參照（見下），但「自己當 marketplace」用同 repo 相對路徑最直接。

### plugin def co-located 至 repo 的 `plugin/` 子目錄

將聚合器的 `plugins/che-ical-mcp/{.claude-plugin/plugin.json, .mcp.json, bin/, commands/, hooks/, rules/}` 遷入本 repo `plugin/`。`marketplace.json` 以 `source: ./plugin`（或 `metadata.pluginRoot: ./` + `source: plugin`）參照。wrapper（`bin/che-ical-mcp-wrapper.sh`）的 binary auto-download 邏輯維持不變。

*替代方案*：放 repo 根——與 Swift `Sources/`、`mcpb/` 混雜，否決；`plugin/` 子目錄邊界清楚。

### `references/` vendored 第三方 code 的處置

聚合器 plugin 內含 `references/mcp-server-apple-reminders/`（第三方 vendored）。遷移時依 Git 隱私邊界與 repo 體積評估：純參考用途者 gitignore 或不納入，僅遷入 plugin 運作實際需要的檔案。

### 跨 channel 單一版本一致性

擴充既有版本一致性機制（#30 的 manifest/`defineTools()` parity）涵蓋新的 `.claude-plugin/marketplace.json` 條目版本與 `plugin/.claude-plugin/plugin.json`，與 `mcpb/manifest.json`、`Version.swift`、`Info.plist` 綁定。release flow 在單一 repo 內一次 bump 全部。

### 聚合器 psychquant-claude-plugins 的關係調整

聚合器的 che-ical-mcp 條目從實體複本改為指向本 repo 的非複本 source（建議 `git-subdir` `{url:"kiki830621/che-ical-mcp", path:"plugin", ref:"<tag>"}`，或 `github`），消除 divergent 複本；或完全移除，改由本 repo 的 self-hosted marketplace 取代。此為 cross-repo step、實作於聚合器 repo，本變更僅描述並在文件記錄遷移指引。

*替代方案*：聚合器保留實體複本——維持現狀的 drift 問題，否決。

## Implementation Contract

**Behavior（使用者可觀察）：**

- 使用者執行 `/plugin marketplace add kiki830621/che-ical-mcp`：Claude Code 從本 repo 根的 `.claude-plugin/marketplace.json` 載入 marketplace，列出 plugin `che-ical-mcp`。
- 使用者執行 `/plugin install che-ical-mcp@che-ical-mcp`：plugin 由同 repo `./plugin` source 安裝，wrapper 仍能 auto-download 對應 release binary。
- plugin 安裝後 commands（`today`、`week`、`remind`、`quick-event`、`check-tcc`）、hooks、rules、`.mcp.json` 行為與現聚合器版本一致。

**Interface / 檔案結構（本 repo）：**

- `.claude-plugin/marketplace.json`：marketplace metadata + 單一 plugin 條目（`name: che-ical-mcp`、`source: ./plugin`、`version`、`description`、`author`、`category`）。
- `plugin/.claude-plugin/plugin.json`、`plugin/.mcp.json`、`plugin/bin/che-ical-mcp-wrapper.sh`、`plugin/commands/*.md`、`plugin/hooks/*`、`plugin/rules/*.md`。

**Failure modes：**

- 相對 source 僅在 git 加入時解析（URL-only 加入會失敗）——README 明載用 git/GitHub 加入。
- 版本不一致 → 既有一致性檢查在 build/release 時 fail。

**Acceptance criteria：**

- `/plugin marketplace add` + `/plugin install` 在乾淨環境成功安裝並可呼叫 commands（手動驗證，記於變更驗證註記）。
- marketplace.json 與 plugin.json 通過 schema/結構檢查（`claude plugin` 相關驗證或 plugin-validator）。
- 版本一致性檢查涵蓋 marketplace.json + plugin.json + mcpb manifest + Swift version，不一致即 fail。
- plugin def 內容與遷移前聚合器版本逐檔對照無遺漏（content review）。

**Scope boundaries：**

- In：本 repo 的 marketplace.json + co-located plugin def + 安裝文件 + 版本一致性 + 遷移指引文件。
- Out：其餘 37 plugin 遷移、聚合器 repo 實際編輯、runtime/TCC 行為、`references/` 中非必要第三方 code。

## Risks / Trade-offs

- [使用者經 URL（非 git）加入 marketplace 時相對 source 解析失敗] → README 明確指示用 `/plugin marketplace add kiki830621/che-ical-mcp`（git 形式）；文檔已載此限制。
- [聚合器與 self-hosted marketplace 並存期間版本可能短暫不一致] → 聚合器條目改為 git-subdir/github 指向本 repo tag，消除實體複本即根除 drift。
- [既有使用者從聚合器安裝，遷移後需重新指向] → README 與遷移指引說明；聚合器條目改為指入本 repo 可維持既有安裝路徑可用。
- [repo 體積因 plugin/references 增加] → `references/` 第三方 code 評估 gitignore，僅納入必要檔。

## Migration Plan

1. 在本 repo 建 `.claude-plugin/marketplace.json` + `plugin/`（遷入聚合器 plugin def）。
2. 更新 README 安裝路徑、擴充版本一致性檢查。
3. 乾淨環境 `/plugin marketplace add` + `install` 手動驗證。
4. （跨 repo）調整聚合器條目指向本 repo 或移除。
5. 將 pattern 文件化供其餘 MCP repo 複用。

Rollback：本變更僅新增檔案（marketplace.json、plugin/）與文件；revert commit 即回到「plugin 僅在聚合器」狀態，聚合器條目未動則使用者不受影響。

## Open Questions

- 聚合器條目最終採 `git-subdir` 指入、或完全移除？—— 屬聚合器 repo 的後續決定，不阻塞本 repo pilot 交付。
- `metadata.pluginRoot` 是否採用以簡化 source 寫法？—— 實作時依 marketplace.json 最終結構定，二者皆可。
