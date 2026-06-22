## Context

`--setup` 是 che-ical-mcp 的人工權限取得 path：使用者從 Terminal 跑它，觸發 macOS TCC dialog 來授權 Calendar / Reminders。在 macOS 14+/26，EventKit 的 `requestFullAccessToEvents()` 彈出的系統 modal 需要請求端是**前景 app（regular activation policy）且有運轉中的 main run loop**。目前 `--setup` 從 bare CLI async context（`await store.requestFullAccessToEvents()`）發出，兩者皆無，導致第一個請求（Calendar）靜默 `denied`、dialog 從不出現，第二個（Reminders）有時滑過（#163）。

兩個失敗面共用同一機制但根因可能不同：
- **(A)** Terminal 直接跑 che-ical-mcp 的 `--setup`：純 dialog-presentation 問題。
- **(B)** 透過 Claude Desktop 的 tool call 被拒（MCP server 是 Claude Desktop spawn 的背景 process）：形狀與 (A) 相同的 Calendar-denied / Reminders-granted 不對稱，但 #163 回覆的新證據（未簽章 v1.7.0 可用、簽章 v1.7.1 起 Calendar 壞）指向可能的殘留簽章/entitlement 根因。

TCC grant 綁 binary 的 code-signing 身分（cdhash / designated requirement），不是綁 team 或 bundle —— 這是設計上的硬約束：獨立 GUI helper app 拿到的 grant 不會轉移給 MCP server binary，唯一能授權到正確身分的是讓 **MCP binary 自己**在前景 context 請求。

## Goals / Non-Goals

**Goals:**

- 互動式 `--setup` 能在 macOS 14+/26 實際 present Calendar 與 Reminders 的 TCC dialog。
- 非互動 session 維持 headless、快速、不卡在不可能出現的 dialog 上。
- tool-call 被拒與 startup banner 對使用者輸出可直接複製貼上的授權指令（解析後 binary 絕對路徑 + `--setup`），含 .mcpb 解壓路徑。
- 提供一個明確的發佈後驗證程序，能一刀切開 (B) 的兩種根因。

**Non-Goals:**

- **不做獨立的 GUI setup app**：TCC 綁 binary 身分，獨立 app 的 grant 無法轉移，且 EventKit 只需前景 app context（非 onboarding UI）。
- **不在本變更追查 (B) 的殘留簽章/entitlement 根因**：若驗證實驗顯示 reset + 前景 `--setup` 後仍拒，該根因另開 idd-diagnose（與 #154 cdhash-pinning 同一族）。
- **不改動非互動 MCP server 的 AuthorizationGate / fast-fail 行為**（#131/#143 已定）。
- **不引入 SwiftUI window 或任何視窗 UI**。

## Decisions

### 互動式 `--setup` 改在前景 NSApplication 的 run loop 內請求權限

互動 path 透過 `SetupRunner.runInteractive()` 取得 `NSApplication.shared`、`setActivationPolicy(.regular)`、掛 `SetupAppDelegate`、`app.run()`。delegate 在 `applicationDidFinishLaunching` 內 `NSApp.activate(ignoringOtherApps:)` 後於 `@MainActor` Task 發出兩個請求，完成即 `exit(bad ? 1 : 0)`。鏡像 che-apple-mail-mcp 的 `SetupWindow.run()`（che-apple-mail-mcp#213）。

*替代方案*：(a) bare CLI async —— 即現狀，dialog 不出現，否決；(b) SwiftUI onboarding window —— 多餘，EventKit 自帶系統 modal，只需前景 context，否決。

### 非互動 `--setup` 維持 headless 狀態回報、永不進 run loop

`main.swift` 以 `NonInteractiveDetection.isNonInteractive(includeCI: false)` 分派（#143/#149：`--setup` 是人工 path，CI=1 不強制 skip）。非互動時呼叫 `SetupRunner.requestBoth(nonInteractive: true)` 走純決策（`setupAccessDecision`）只報 already-granted / skip / denied 並 `exit`，不進 NSApplication run loop（dialog 在此本來就無法出現）。

### tool-call 被拒與 startup banner 嵌入 binary 路徑與 `--setup` 指令

當 EventKit tool call 因權限失敗時，denial message（經 `EventKitManager` 既有 guidance 路徑）與 `--print-tcc-path` / banner（`TCCDriftDetector`）輸出**由 `BinaryPathResolver` 解析的當前 binary 絕對路徑**與 `"<path>" --setup` 一行指令。對 .mcpb 安裝，這條路徑就是 `~/Library/Application Support/Claude/Claude Extensions/.../server/CheICalMCP`，使用者得以授權到正確的 binary 身分。

*替代方案*：只叫使用者「去 System Settings 開啟」—— 對 .mcpb 使用者無法定位該 binary、且 binary 可能未出現在清單，否決。

### (B) 根因二分的發佈後驗證實驗（程序，非 code）

定義並文件化實驗：`tccutil reset Calendar <bundleID>` → 跑 .mcpb 解壓 binary 的 `--setup`（含本變更的前景 NSApplication 修復）。結果分類：dialog 出現、授權後 tool call 通 → (B) 屬 dialog-presentation，本變更解決；reset + 前景 `--setup` 後仍拒 → (B) 屬殘留簽章/entitlement root cause，超出本變更，另開 idd-diagnose。此實驗需 notarized build（`make release-signed`），並請 #163 回覆者 LittleCoinCoin 協助實測。

### 非 AppKit 平台的 best-effort fallback

`#if canImport(AppKit)` 之外（非 macOS）以 semaphore-pumped 的 `requestBoth` 退化處理，保持跨平台 build 不破。此為純防禦，macOS 為唯一實際 target。

## Implementation Contract

**Behavior（使用者可觀察）：**

- 在 Terminal（互動 session）跑 `<binary> --setup`：依序出現 Calendar 與 Reminders 的系統 TCC dialog；使用者按 Allow 後印出 `Calendar access: ✓ granted` / `Reminders access: ✓ granted`，exit 0；任一被拒則印 `✗ denied` 並附手動授權指引，exit 1。
- 在非互動 session（無 TTY / 被偵測為非互動）跑 `--setup`：印出 WARNING + 各 entity 的 already-granted / skip / denied 狀態，**不**阻塞於 dialog，立即 exit。
- 當 Calendar / Reminders 權限不足導致 tool call 失敗：回應與 startup banner 含一行可複製的 `"<resolved-absolute-binary-path>" --setup`。

**Interface / 命令：**

- `SetupRunner.runInteractive() -> Never`（互動入口，前景 NSApplication）。
- `SetupRunner.requestBoth(nonInteractive: Bool) async -> Bool`（回傳 anyBad；`@MainActor`）。
- `SetupRunner.printGuidanceIfNeeded(_ bad: Bool)`。
- `main.swift` `--setup` 分派：非互動 → `requestBoth(nonInteractive:true)` + exit；互動 → `runInteractive()`。

**Failure modes：**

- 請求 throw（framework error）→ 經 `EventKitErrorSanitizer.escapeForStderr` 清洗後印出、計入 anyBad。
- 非互動 + 需請求 → 印 `⤼ skipped`（不嘗試會 block 的 dialog），計入 anyBad。

**Acceptance criteria：**

- 新增/維持單元測試：`setupAccessDecision` 各分支、`requestBoth` 透過注入 source 的 already-granted / denied / skip / writeOnly / error 路徑、denial message 含解析路徑 + `--setup`。
- `swift build -c release` clean。
- 既有 banner skip-list 測試不回歸（`--setup` 仍不 emit startup banner，CLAUDE.md #122/#130 已定）。
- notarized build 上手動驗證互動 dialog present（記錄於變更的驗證註記）。

**Scope boundaries：**

- In：`--setup` 前景化、denial/banner 授權引導、驗證實驗文件化、SetupRunner 測試。
- Out：(B) 殘留簽章根因診斷、AuthorizationGate 改動、任何視窗 UI、其他 che-* MCP 的同類遷移（屬 Idea 2 / 各自變更）。

## Risks / Trade-offs

- [前景 NSApplication 在某些 sandbox / headless 環境啟動失敗] → 互動 path 僅在偵測為互動時進入；非互動永遠走 headless，不觸發 NSApplication。
- [notarized build 才能真實驗證 dialog 行為，round-trip 2–10 分鐘] → 接受；ad-hoc 在 macOS 26 會被 SIGKILL，無法用於驗證。
- [(B) 可能根因二未被本變更解決] → 明確列為 Non-Goal，並以驗證實驗即時暴露、導向 idd-diagnose，避免誤以為已修。
- [denial message 印出絕對路徑可能含使用者名稱等路徑資訊] → 僅本機 stderr / 回應，非外送；路徑經既有 `escapeForStderr` 控制字元清洗。

## Migration Plan

1. Commit 既有未追蹤的 `SetupRunner.swift` 與相關改動，補測試。
2. `make release-signed` 出 notarized build + `.mcpb`。
3. 互動 dialog 手動驗證（A）。
4. 跑 (B) 驗證實驗（reset → .mcpb `--setup`），記錄結果。
5. 依結果決定是否另開 idd-diagnose 追 (B) 根因二。

Rollback：本變更僅改 `--setup` 與訊息文字，無資料遷移；revert commit 即可回到 bare CLI `--setup`。

## Open Questions

- (B) 在帶 entitlement 的 v1.11+ 上、做 `tccutil reset` 後是否就能授權成功？—— 由驗證實驗回答，是本變更交付後的第一個待決點。
