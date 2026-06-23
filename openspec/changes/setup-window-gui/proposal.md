## Why

#163 讓互動式 `--setup` 的前景 `NSApplication` 能讓 macOS 系統 TCC 授權框真正彈出，但 `--setup` 對使用者（尤其 Claude Desktop `.mcpb` 安裝）仍是黑盒：看不到目前 Calendar/Reminders 狀態、不知道正在授權**哪一支** binary（`.mcpb` binary 埋在 `~/Library/.../Claude Extensions/local.mcpb.…/server/CheICalMCP`）、被 deny 後也不知道要改去 System Settings。本變更在既有前景 `NSApplication` 內掛一個 SwiftUI **SetupWindow**，補上這三個認知缺口——這正是 #163 最初討論裡「用 GUI 解決」想要的東西（issue #164）。

鏡像 che-apple-mail-mcp 的 `SetupWindow`（che-apple-mail-mcp#213），但更完整：FDA 沒有 request API、只能引導去 System Settings + 輪詢；EventKit 有 `requestFullAccess*`，所以 SetupWindow 可放**直接觸發系統授權框的按鈕**。

## What Changes

- **新增 SwiftUI SetupWindow**：互動式 `--setup` 改為在前景 `NSApplication` 內呈現一個視窗（`NSHostingController(SetupView())`），而非目前的「無視窗、直接 fire 兩個請求」。
- **視窗內容**：Calendar / Reminders 各一列 live 狀態點（🟢/🔴）+ `[Grant <entity> access]` 按鈕（直接呼 `requestFullAccess…` 彈系統框）；解析後的 binary 絕對路徑（等寬可選取）+ `[Open System Settings]`（deny 後 fallback，deep-link Privacy & Security → Calendar）+ `[Copy binary path]`；兩者皆 granted 時顯示綠色 Ready。
- **Live 輪詢**：~1.5s `Timer` 重讀 `authorizationStatus` → 授權瞬間翻 🟢 / Ready。
- **非互動 / 非 SwiftUI 平台**：維持 #163 的 headless `requestBoth`（不開視窗、只報狀態並 exit）；stdio MCP path 永不進視窗 runloop。
- 重用既有 `SetupAccessDecision`、`SetupRunner.evaluateEntity`、`BinaryPathResolver`，不新增 TCC 邏輯。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `setup-permission-flow`: 既有「互動式 `--setup` 在前景 app context 請求權限」擴充為「呈現一個顯示 live 狀態、提供直接 Grant 按鈕、顯示授權目標 binary 路徑、並在授權後即時翻 Ready 的 SetupWindow」。非互動 headless 行為與權限決策不變。

## Impact

- Affected specs: 修改 `setup-permission-flow`（ADDED requirements，視窗相關）
- Affected code:
  - `Sources/CheICalMCP/SetupWindow.swift`（新檔：`SetupView` + `SetupModel` + 視窗 host）
  - `Sources/CheICalMCP/SetupRunner.swift`（`runInteractive()` 改為呈現視窗；`evaluateEntity` / `requestBoth` 沿用）
  - `Sources/CheICalMCP/SetupAccessDecision.swift`、`EventKit/BinaryPathResolver.swift`（沿用）
  - `Tests/CheICalMCPTests/`（`SetupModel` 狀態映射 / grant 結果 → 狀態 / 路徑 的單元測試；SwiftUI view 本身不單測）
  - `Version.swift` / `Info.plist` / `mcpb/manifest.json` / `.claude-plugin/marketplace.json` / `plugin/.claude-plugin/plugin.json`（版本同步，由既有一致性檢查綁定）
- 關聯 issue：#164（本體）、#163（前置 NSApplication）；模式參照 che-apple-mail-mcp#213。
