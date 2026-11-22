## 1. 先紅

這一組到第 3 組實作 requirement「An edited occurrence's recorded slot is read as an instant, and a whole-series delete forecasts its undo」。

- [x] 1.1 An edited occurrence's recorded slot is read as an instant, and a whole-series delete forecasts its undo（先紅）：dry run 的擷取對不透明 id 的場次與同一時段的兩個場次，跟實際呼叫的擷取相同；驗證：在 `8e642f4e` 的時段式切割上紅

## 2. 移除裁定 F 與 J，dry run 以識別碼切割

- [x] 2.1 移除 F、J 與只為它們存在的程式，時段檢查、origin、單一場次與 split move 的 undo、批次 undo 回到 `main`；驗證：`main` 的測試全部保留且通過，鏈測試與矩陣與 `main` 相同
- [x] 2.2 dry run 經由 `DryRunCaptureStore` 在擷取之前以識別碼排除較早的列刪掉的場次；驗證：1.1 綠、wiring 釘選
- [x] 2.3 測試：Q4（`main` 的一邊用 92d9b796 的 restore）、Q5/P14/P20（矩陣的說法）、P4（鏈比對文字，加上 MA 的鏈）；被移除的測試以（檔案、名稱）對 `8e642f4e` 與 `origin/main` 列出

## 3. 文字

- [x] 3.1 `Server.swift`、manifest、兩個 README、CHANGELOG `[Unreleased]`、gate 的 #539 一節、spec：undo 是 `main` 的，這個 PR 加上刪除時的預告與 #541 的文字，#539 沒有修好；移除 F 與 J 的說法；Q9、Q11 的措辭

## 4. 證明

- [x] 4.1 mutant：預告的條件、dry run 的切割（拿掉、改成時段式）、每一段新文字，各自紅
- [x] 4.2 三個時區完整測試、0 失敗
- [x] 4.3 iCloud 裝置格（這一輪的簽章 build）：`delete_event` span all、span future，`delete_events_batch` dry run 與實際呼叫的預告
