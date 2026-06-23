## Why

macOS 14+/26 上，EventKit 的 `requestFullAccessToEvents()` 會彈出系統 modal，這個 modal **要求請求端是前景 app（regular activation policy）且有正在運轉的 main run loop** 才能 present。che-ical-mcp 的 `--setup` 從 bare CLI async context 發出請求（既非前景 app、也無 pumping 的 run loop），導致**第一個**請求（Calendar）靜默回傳 `denied` 而 dialog 從不出現，**第二個**請求（Reminders）有時反而滑過——使用者實測就是 `Calendar ✗ denied / Reminders ✓ granted` 的不對稱（#163）。

此外，issue #163 的回覆帶來一個被 git 史證實、會改變診斷方向的新證據：簽章 + notarization 正是在 **v1.7.1**（commit `f04fdf8`, #44）落地的，而使用者 LittleCoinCoin 在 macOS 26.5.1 + 現行 Claude Desktop 實測「未簽章的 v1.7.0 透過 Claude Desktop 的 Calendar tool call 至今可用，簽章的 v1.7.1 起 Calendar 被靜默拒絕、Reminders 仍可用」。這個不對稱與 #163 的 dialog-presentation 不對稱**形狀相同**，但根因可能不同（簽章後缺 entitlement / cdhash-pinning），目前無法分辨。需要一個**能一刀切開兩種根因**的可發佈修復 + 驗證程序。

## What Changes

- **(A) 前景 `--setup`**：互動式 `--setup` 改在前景 `NSApplication`（`setActivationPolicy(.regular)` + delegate + `app.run()`）的 run loop 內發出 Calendar / Reminders 請求，使 TCC dialog 能 present。非互動 path 維持 headless（只報狀態、永不進 run loop）。鏡像 che-apple-mail-mcp 的 `SetupWindow.run()`（che-apple-mail-mcp#213），但不含 SwiftUI window（EventKit 有 request API，只需前景 app context，不需 onboarding UI）。
- **(B) 授權引導 UX**：當透過 Claude Desktop 的 tool call 因權限被拒、以及 startup banner 偵測到 Calendar 未授權時，輸出**解析後的當前 binary 絕對路徑**（含 .mcpb 解壓路徑）+ 對應的 `"<path>" --setup` 一行指令，引導使用者去授權正確的 binary 身分。利用既有的 `BinaryPathResolver` / `--print-tcc-path` 機制。
- **驗證實驗（B 根因二分）**：定義並文件化「`tccutil reset Calendar <bundleID>` → 跑 .mcpb 解壓 binary 的 `--setup`」實驗。實驗結果決定 B 的歸類：dialog 出現且授權後 tool call 通 → B 屬 dialog-presentation（本變更解決）；reset + 前景 `--setup` 後仍拒 → B 屬殘留簽章/entitlement root cause，**超出本變更範圍**，另開 idd-diagnose 追查。
- 既有 `SetupRunner.swift`（目前未 commit）正式納入並補測試；`main.swift` 的 `--setup` 分派、`Version.swift` 的 help 文字、`Info.plist` / `mcpb/manifest.json` 的相關改動一併納入此變更。

## Capabilities

### New Capabilities

- `setup-permission-flow`: che-ical-mcp 取得 Calendar / Reminders TCC 權限的設定流程 —— 互動式前景 `--setup` 的 dialog presentation、非互動 headless 狀態回報、以及 tool-call 被拒 / banner 偵測時對使用者的授權引導（binary 路徑 + `--setup` 指令）。

### Modified Capabilities

(none)

## Impact

- Affected specs: 新增 `setup-permission-flow`
- Affected code:
  - `Sources/CheICalMCP/SetupRunner.swift`（新檔，formalize）
  - `Sources/CheICalMCP/main.swift`（`--setup` 分派至 `SetupRunner`）
  - `Sources/CheICalMCP/SetupAccessDecision.swift`（純決策，沿用）
  - `Sources/CheICalMCP/NonInteractiveDetection.swift`（互動偵測，沿用）
  - `Sources/CheICalMCP/EventKit/EventKitManager.swift`（tool-call 被拒時的 denial message 加入 binary 路徑 + `--setup` 指令）
  - `Sources/CheICalMCP/EventKit/BinaryPathResolver.swift` / `TCCDriftDetector.swift`（banner 授權引導，沿用既有路徑解析）
  - `Sources/CheICalMCP/Version.swift`、`Info.plist`、`mcpb/manifest.json`（版本 / help / manifest 同步）
  - `Tests/CheICalMCPTests/`（SetupRunner 與 denial-message 路徑的測試）
- Distribution / 驗證：需 `make release-signed` 出 notarized build 才能在 macOS 26 實測 TCC dialog 行為（ad-hoc 會被 SIGKILL）。
- 關聯 issue：#163（本體）、#154（cdhash-pinning / entitlement 背景）、#155 / #157 / #158（sister concerns）。
