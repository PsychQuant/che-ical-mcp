## 1. SetupModel — 可測的狀態 / grant / path seam

實作 design 決策 **SetupModel 把狀態 / grant / path 抽成可測 seam**。

- [x] 1.1 新增 `@MainActor final class SetupModel: ObservableObject`：`@Published` 持有 Calendar/Reminders 顯示狀態 + 解析 binary 路徑；status 讀取與 grant 透過注入 closure（預設接真實 `EKEventStore`，重用 `SetupRunner.evaluateEntity` / `SetupAccessDecision`），路徑用 `BinaryPathResolver`。驗證：`SetupModel` 單元測試（注入 fake probe）涵蓋 status→顯示狀態（granted/denied/notDetermined/writeOnly/error）、grant 結果→狀態更新、path 來源。
- [x] 1.2 實作 design 決策 **Live 輪詢 authorizationStatus 翻 Ready**：`start()` 起 ~1.5s repeating `Timer` 重讀狀態、`stop()`/`onDisappear` invalidate，且 `start()` idempotent（先 `stop()`，避免重入洩漏第二個 timer）。驗證：單元測試斷言重複 `start()` 不累積 timer（或 refresh 後狀態更新）。

## 2. SetupWindow 視窗 + runInteractive 接線

實作 spec 需求 **Interactive --setup presents a window showing live Calendar and Reminders status** 與 **The window grants access directly and surfaces the authorization target binary**，及 design 決策 **互動式 `--setup` 改為呈現 SwiftUI SetupWindow** 與 **Grant 按鈕直接觸發 requestFullAccess（EventKit 優勢）**。

- [x] 2.1 交付 spec 需求 **Interactive --setup presents a window showing live Calendar and Reminders status** 與 **The window grants access directly and surfaces the authorization target binary**：新增 `Sources/CheICalMCP/SetupWindow.swift`：`SetupView`（Calendar/Reminders 各一列狀態點 + `[Grant <entity> access]`；binary 路徑等寬可選取 + `[Open System Settings]` deep-link + `[Copy binary path]`；兩者 granted 顯示 Ready）+ `SetupAppDelegate`（`NSHostingController(SetupView())` 視窗、約 480×460、置中、`applicationShouldTerminateAfterLastWindowClosed` 回 true）+ `SetupWindow.run()`。驗證：`swift build -c release` clean；notarized build 手動驗證視窗呈現、Grant 彈系統框、binary 路徑正確、Copy/Open Settings 可用（記於變更驗證註記）。
- [x] 2.2 `SetupRunner.runInteractive()` 互動分支改呼 `SetupWindow.run()`（取代直接 `requestBoth` 後 exit）。驗證：`--setup` 互動時進入視窗 path；既有非互動 `--setup` 測試與 banner skip-list 不回歸。

## 3. 非 SwiftUI / 非互動 fallback

- [x] 3.1 [P] 實作 design 決策 **非 SwiftUI / 非互動平台維持 headless fallback**：`#if canImport(AppKit) && canImport(SwiftUI)` 之外 degrade 到既有 `requestBoth`；非互動 session 仍 headless 報狀態 + exit、永不進視窗 runloop。驗證：條件編譯 review；非互動 `--setup` 行為不變測試通過。

## 4. 版本同步

- [x] 4.1 [P] 同步 `Version.swift` / `Info.plist` / `mcpb/manifest.json` / `.claude-plugin/marketplace.json` / `plugin/.claude-plugin/plugin.json` 至本變更版本。驗證：`VersionConsistencyTests` 與 build-mcpb.sh 版本一致性檢查通過。

## 5. 發佈 + 手動視窗驗證

- [ ] 5.1 出 notarized build（`make release-signed`）並手動驗證 SetupWindow：互動 `--setup` 開窗、Grant 彈框、授權後翻 Ready、binary 路徑/Copy/Open Settings 正確。驗證：notarytool Accepted；手動視窗驗證結果記於變更驗證註記（需真人）。
