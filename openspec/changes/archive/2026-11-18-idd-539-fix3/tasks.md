## 1. 矩陣（先紅）

這一組到第 3 組實作 requirement「An edited occurrence's recorded slot is read both ways」的修改。

- [x] 1.1 An edited occurrence's recorded slot is read both ways（矩陣先紅）：`FloatingSeriesUndoMatrixTests` 加上 J1 的兩種形狀（真正的時段在視窗結束之後的年輕開放式系列、在視窗開始之前開始的系列），每一格兩種讀法的格子斷言照規則重建的行事曆、計數為 0、沒有兩個事件同一個開始時間、文字說出原因；驗證：在 `c569fe68` 上 J1 的格子紅

## 2. 撤回

- [x] 2.1 An edited occurrence's recorded slot is read both ways（撤回）：還原在擷取有兩種讀法的紀錄時不套用任何例外，`Outcome` 帶自己的原因，單一與 batch 的文字說出原因；移除裁定 B、C、D、I、14 小時的邊距列出與擷取上的 stand-in 紀錄；驗證：矩陣全綠，兩種讀法的格子沒有一格套用，一種讀法的格子與 `main` 相同
- [x] 2.2 刪除時的預告：擷取有兩種讀法的紀錄時把每一筆修改都算進去，`undo_note`／`rules_alone_on_undo` 說同一個原因；一種讀法的紀錄維持原本的預告；驗證：預告的測試與 handler 測試
- [x] 2.3 被移除裁定的測試改寫或移除，以（檔案、名稱）對 `c569fe68` 與 `origin/main` 列出

## 3. 文字

- [x] 3.1 `Server.swift` 的描述（`delete_event`、`delete_events_batch`、`undo`）、manifest、README、README_zh-TW、CHANGELOG `[Unreleased]`、gate 說出程式現在做的事：沒有時區的系列的修改不由整個系列刪除的 undo 還原，刪除時有預告，#539 保持 open
- [x] 3.2 J5：重做 DS1、FR、FW 並記錄答案，更正與記錄不符的舊紀錄；第三輪仍成立的 LOW 與 INFO 文字（J7、J8、J14 到 J25）

## 4. 證明

- [x] 4.1 mutant：重新啟用兩種讀法紀錄的放置、拿掉預告的新條件、拿掉原因的文字，各自紅
- [x] 4.2 三個時區完整測試、0 失敗；對 `c569fe68` 與 `origin/main` 以（檔案、名稱）列出移除的測試
- [x] 4.3 iCloud 裝置格（新的簽章 build）：F1、D2、MA、FR、S1、S2、N1、DS1、SD、FW 與 #538 的 sequence 1、8
