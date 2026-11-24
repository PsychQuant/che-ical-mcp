<!--
沒有 [P]：每個 task 都以 build 或測試結束，這台機器一次只跑一個 build（共用的 build 鎖）。
測試先寫；每個新文字拿掉時要看到對應的測試失敗（紅），記在 PR body 的 mutation 表。
-->

## 1. 文字（`UndoGuardErrors.swift`）

- [x] 1.1 先寫 `UndoChangedSourceTests`（純函式）：事件與提醒事項的 undo 文字、兩種的 redo 文字都列出 another app、calendar server 與本 server 沒有紀錄的後續操作；提醒事項仍有 failed write，事件沒有；沒有「Whoever made the change」；固定開頭與 #265 的 note 不變。看到紅，再改 `changedBy` 與兩段 revertable 文字，看到綠。

## 2. 規格與文件

- [x] 2.1 delta spec：`undo-history-discard` 新增 requirement「Changed-after refusal names the sources it cannot tell apart」。`spectra validate` 通過。
- [x] 2.2 `CHANGELOG.md` `[Unreleased]` 的 Fixed 一條。README、tool description、manifest 沒有描述這段文字的來源，確認不需要改。

## 3. 證明

- [x] 3.1 完整 `swift test` 三個時區（主機、`TZ=UTC`、`TZ=America/Los_Angeles`）0 failures；移除測試檢查（對 `origin/main` 以 (檔案, 名稱) 比對）；mutation 表（每段新文字一個 mutant，看到紅）。
- [-] 3.2 裝置格：不做。只改錯誤文字，純函式測試涵蓋兩個 arm；觸發形狀（discard 之後的較舊紀錄）是 #484 run G 量過的形狀。
