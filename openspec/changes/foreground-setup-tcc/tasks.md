## 1. 互動式 `--setup` 改在前景 NSApplication 的 run loop 內請求權限

實作 spec 需求 **Interactive --setup presents TCC dialogs from a foreground app context**。

- [ ] 1.1 交付 **Interactive --setup presents TCC dialogs from a foreground app context**：將未追蹤的 `SetupRunner.swift` 正式納入，`runInteractive()` 以前景 `NSApplication`（`setActivationPolicy(.regular)` + `SetupAppDelegate` + `app.run()`）在 run loop 內發出 Calendar、Reminders 請求，使 TCC dialog 能 present。驗證：互動 session 下兩個 TCC dialog 依序 present（notarized build 手動實測，記於變更驗證註記）。
- [ ] 1.2 `main.swift` 的 `--setup` 互動分支呼叫 `SetupRunner.runInteractive()`（非互動分支見 2.1）。驗證：`swift build -c release` clean，且 `--setup` 互動時進入前景 app path。
- [ ] 1.3 為 `setupAccessDecision` 各分支（alreadyGranted / requestAccess / skipWouldBlock / denied / writeOnly）補/維持單元測試。驗證：`swift test` 對應測試通過。
- [ ] 1.4 [P] 為 `SetupRunner.requestBoth` 經注入 source 驗 already-granted / denied / writeOnly / error（sanitized）路徑的輸出與 anyBad 回傳。驗證：新增的 SetupRunner 測試通過。
- [ ] 1.5 [P] 實作並測試**非 AppKit 平台的 best-effort fallback**：`#if canImport(AppKit)` 之外以 semaphore-pumped `requestBoth` 退化，保持跨平台 build 不破。驗證：非 macOS build path 編譯通過（條件編譯 review）。

## 2. 非互動 `--setup` 維持 headless 狀態回報、永不進 run loop

實作 spec 需求 **Non-interactive --setup reports status without blocking on a dialog**。

- [ ] 2.1 交付 **Non-interactive --setup reports status without blocking on a dialog**：`main.swift` 以 `NonInteractiveDetection.isNonInteractive(includeCI: false)` 分派非互動 `--setup` 至 `SetupRunner.requestBoth(nonInteractive: true)` + `printGuidanceIfNeeded` + exit，永不進 NSApplication run loop。驗證：非互動 session 印 WARNING + skip/already-granted 並立即 exit（不阻塞）。
- [ ] 2.2 [P] 確認 `--setup` 仍不觸發 startup banner（CLAUDE.md #122/#130 skip-list）。驗證：既有 banner skip-list 測試不回歸。

## 3. tool-call 被拒與 startup banner 嵌入 binary 路徑與 `--setup` 指令

實作 spec 需求 **Permission-denied responses surface the resolvable binary path and --setup command**。

- [ ] 3.1 交付 **Permission-denied responses surface the resolvable binary path and --setup command**：`EventKitManager` 權限不足的 denial guidance 加入由 `BinaryPathResolver` 解析的絕對 binary 路徑 + `"<path>" --setup` 指令（經 `escapeForStderr` 清洗）。驗證：新增測試斷言 denial 文字含解析路徑與 `--setup`。
- [ ] 3.2 [P] startup banner（`TCCDriftDetector`）偵測 Calendar 未授權時，輸出含解析路徑 + `"<path>" --setup`。驗證：banner 測試斷言未授權情境含該指令。

## 4. 版本 / manifest / help 同步

- [ ] 4.1 [P] 同步 `Version.swift` help 文字、`Info.plist`、`mcpb/manifest.json` 至本變更版本，維持既有 manifest/`defineTools()` parity（#30）。驗證：version 一致性 build-time 檢查與 manifest parity 測試通過。

## 5. 發佈後驗證：(B) 根因二分的發佈後驗證實驗（程序，非 code）

- [ ] 5.1 出 notarized build：`make release-signed` 產生簽章 + notarized binary 與 `.mcpb`。驗證：`xcrun notarytool` 成功、`codesign -dv` 顯示 Developer ID + personal-information entitlements。
- [ ] 5.2 執行 **(B) 根因二分的發佈後驗證實驗（程序，非 code）**：`tccutil reset Calendar <bundleID>` → 跑 .mcpb 解壓 binary `--setup` → 試 Calendar tool call。依結果分類（dialog-presentation 已解 / 殘留簽章根因 → 另開 idd-diagnose），記於變更驗證註記。驗證：實驗結果與分類已書面記錄；請 #163 回覆者 LittleCoinCoin 協助實測。
