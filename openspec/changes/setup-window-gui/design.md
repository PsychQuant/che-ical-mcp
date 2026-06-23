## Context

#163 的 `SetupRunner.runInteractive()` 目前在前景 `NSApplication` 內，於 `applicationDidFinishLaunching` 直接 `await requestBoth(...)` 兩個請求後 `exit`——無視窗。系統 TCC 框會彈，但使用者看不到狀態、不知授權哪支 binary、deny 後無引導。che-apple-mail-mcp#213 的 `SetupWindow` 用 `NSHostingController(SetupView())` + 1.5s `Timer` 輪詢解決同類問題（FDA），但 FDA 無 request API 故只能引導去設定；EventKit 有 `requestFullAccessToEvents/Reminders`，視窗可直接觸發系統框。

既有可重用元件：`SetupAccessDecision`（純決策）、`SetupRunner.evaluateEntity(status:nonInteractive:request:)`（注入式分支邏輯，#163 已抽）、`BinaryPathResolver.resolveArgv0`（解析授權目標路徑）、`EventKitErrorSanitizer`（清洗）。

## Goals / Non-Goals

**Goals:**

- 互動式 `--setup` 呈現一個視窗：Calendar/Reminders live 狀態、直接 Grant 按鈕、授權目標 binary 路徑、Open Settings/Copy 按鈕、授權後即時翻 Ready。
- 視窗邏輯（狀態映射、grant 結果處理、路徑）抽成可單元測試的 model，不依賴真實 `EKEventStore` 或 SwiftUI render。
- 非互動 / 非 SwiftUI 平台維持 #163 的 headless 行為。

**Non-Goals:**

- **不做獨立 helper app**：TCC 綁 binary 身分，獨立 app 的 grant 不轉移（#163 已定）。視窗在 MCP binary 自己的 `--setup` 內。
- **不改權限決策 / 非互動 fast-fail**（`SetupAccessDecision` / `AuthorizationGate` 不動）。
- **不單測 SwiftUI view 本身**（render 層）；只測 model。
- **不在本變更追 (B) Claude Desktop 殘留簽章根因**（屬 #163 5.2 / 另開 idd-diagnose）。

## Decisions

### 互動式 `--setup` 改為呈現 SwiftUI SetupWindow

`SetupRunner.runInteractive()` 的 `SetupAppDelegate.applicationDidFinishLaunching` 改為建立 `NSWindow(contentViewController: NSHostingController(rootView: SetupView()))`（titled/closable/miniaturizable，約 480×460，置中、`makeKeyAndOrderFront`、`NSApp.activate`），取代目前的「直接 `requestBoth` 後 exit」。視窗關閉 → `applicationShouldTerminateAfterLastWindowClosed` 回 true → 程式結束。

*替代方案*：維持無視窗（現狀）——黑盒、否決；獨立 app——TCC 不轉移、否決。

### SetupModel 把狀態 / grant / path 抽成可測 seam

新增 `@MainActor final class SetupModel: ObservableObject`，`@Published` 持有 Calendar/Reminders 的 `EKAuthorizationStatus`（或映射後的顯示狀態）與解析路徑。狀態讀取與 grant 觸發透過注入的 closure（預設接真實 `EKEventStore`；測試注入 fake），重用 `SetupRunner.evaluateEntity`。如此 model 的「status → 顯示狀態」「grant 結果 → 更新狀態」「path 來源」可在無 `EKEventStore`、無 SwiftUI 下單元測試。命名依 CLAUDE.md `<Domain>Source` 慣例（如 `SetupAccessProbing`）。

*替代方案*：邏輯寫在 SwiftUI View 內——不可測、否決。

### Grant 按鈕直接觸發 requestFullAccess（EventKit 優勢）

`[Grant Calendar access]` / `[Grant Reminders access]` 呼 model 方法 → `requestFullAccessToEvents/Reminders()` → 系統框彈出。這是相對 che-apple-mail-mcp（FDA 無 request API、只能 Open Settings）的增益。被 deny 後 `requestFullAccess` 不再彈框，故同時提供 `[Open System Settings]` deep-link 作 fallback。

### Live 輪詢 authorizationStatus 翻 Ready

`SetupModel.start()` 起一個 ~1.5s repeating `Timer` 重讀 `authorizationStatus`，使視窗在使用者於系統框/設定授權後即時翻 🟢 / Ready；`onDisappear` / `stop()` invalidate（idempotent，避免 miniaturize 重入洩漏第二個 timer）。`authorizationStatus` 為 cheap read、不彈框。

### 非 SwiftUI / 非互動平台維持 headless fallback

`#if canImport(AppKit) && canImport(SwiftUI)` 之外 degrade 到既有 `requestBoth`（無視窗）。非互動 session（#163 偵測）仍走 headless 狀態回報 + exit，永不進視窗 runloop；stdio MCP path 不受影響。

## Implementation Contract

**Behavior（使用者可觀察）：**

- 互動式 `<binary> --setup`：開一個視窗，列 Calendar 與 Reminders 的目前狀態（granted/denied/not-determined）、各一顆 Grant 按鈕、授權目標 binary 的絕對路徑、Open System Settings 與 Copy binary path 按鈕；按 Grant 在 `.notDetermined` 時彈系統框；授權後該列 ~1.5s 內翻 granted，兩者皆 granted 顯示 Ready；關窗即退出。
- 非互動 `--setup`：不開視窗，印狀態（already-granted / skip / denied）並 exit（與 #163 同）。
- stdio MCP server 模式：完全不進視窗路徑。

**Interface：**

- `SetupWindow.run() -> Void`（`@MainActor`，前景 NSApplication + 視窗 host）。
- `SetupModel`（`@MainActor`, ObservableObject）：`@Published` Calendar/Reminders 顯示狀態 + path；`refresh()`、`start()`/`stop()`（timer）、`grant(_ entity)`、`openSettings()`、`copyPath()`。
- `SetupRunner.runInteractive()` 互動分支改呼 `SetupWindow.run()`；非互動分支不變。

**Failure modes：**

- grant throw → 經 `EventKitErrorSanitizer` 清洗後於該列顯示錯誤態（沿用 `evaluateEntity` 的 `.error`）。
- 非 AppKit/SwiftUI build → headless fallback。

**Acceptance criteria：**

- `SetupModel` 單元測試：注入 fake probe 驗 status→顯示狀態（granted/denied/notDetermined/writeOnly/error）、grant 結果→狀態更新、path 來源；timer idempotent（start 兩次不洩漏）。
- `swift build -c release` clean；既有 `--setup` 非互動測試、banner skip-list 不回歸。
- notarized build 上手動驗證視窗呈現 + Grant 彈框 + 翻 Ready（記於變更驗證註記，需真人）。

**Scope boundaries：**

- In：SetupWindow（view + model + host）、runInteractive 改接視窗、model 單元測試、版本同步。
- Out：(B) 簽章根因、非互動/權限決策改動、SwiftUI view render 層測試、其他 che-* MCP。

## Risks / Trade-offs

- [SwiftUI/AppKit 連結進 binary 增加體積 / 載入] → 僅 `--setup` 啟動 runloop；stdio path 不進入（che-apple-mail-mcp#213 已驗證此 gating 模式可行）。
- [Timer 在 miniaturize 重入洩漏第二個 timer] → `start()` 先 `stop()`（idempotent），鏡像 mail 的 SetupModel。
- [視窗呈現只能真人驗證] → model 邏輯單元測試涵蓋；render + 系統框為手動驗證項（與 #163 5.2 同性質）。
- [grant 後若仍是 .mcpb 殘留根因] → 視窗會誠實顯示仍 denied；不誤報，導向 #163 5.2 / 新 idd-diagnose。

## Migration Plan

1. 新增 SetupWindow.swift（view + model）+ runInteractive 改接。
2. 補 SetupModel 單元測試。
3. 版本 bump（5 artifact 一致）+ CHANGELOG。
4. `make release-signed` 出 notarized build；手動驗證視窗。
5. 發佈 + marketplace 同步（如 #163）。

Rollback：revert 即回到 #163 的無視窗 `--setup`（headless requestBoth 仍在）。

## Open Questions

- 視窗是否需要「全部 Grant」單鍵（一次請求兩者）？—— 實作時若兩顆獨立按鈕已夠直覺則略；不阻塞。
