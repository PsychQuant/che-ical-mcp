<!--
#540 verify round 1 的修正。測試先寫，看到紅再改；每個新斷言一個 mutant，看到紅。
-->

## 1. 錯誤文字（E1、E3、E9、E10）

- [x] 1.1 `UndoChangedSourceTests` 改成整句比對 undo（事件、提醒事項）與 redo 文字，`whoever` 不分大小寫；看到紅，再改 `UndoGuardErrors.swift`：undo 說經本 server 改回會在上面記一筆、下一次 undo 先處理它、要先用 discard_id 放棄；redo 請在其他 app 改回，經本 server 用 complete_reminder。

## 2. 其他文字（E1、E2、E4、E5）

- [x] 2.1 新增 `UndoChangedSourceDocsTests`（每個新句子在各自文件恰好一次，舊句子不再出現），看到紅，再改 `undo` 工具說明、manifest summary、README.md、README_zh-TW.md、docs/UNDO_HISTORY.md、CHANGELOG 的 #538、#484、#540 三條。
- [x] 2.2 delta spec：`undo-history-discard` 的 #538 與 #540 兩個 requirement（MODIFIED）。`spectra validate` 通過。

## 3. 紀錄（E6、E7、E8）

- [x] 3.1 前一個 change 的 tasks 1.1、2.2 的更正寫在本 proposal；它 `.openspec.yaml` 的 e-mail 拿掉（本 PR 新增的檔案都只留名字）。
- [x] 3.2 PR body 與 Implementation Complete 照原文引用 Diagnosis 計畫的 redo 文字，說明計畫改了；Diagnosis 加一則 note。

## 4. 證明

- [x] 4.1 完整 `swift test` 三個時區 0 failures；移除測試檢查；mutants。
