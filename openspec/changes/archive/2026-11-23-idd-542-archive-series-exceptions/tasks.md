<!--
沒有 [P]：每個 task 都以 build、測試或文件比對結束，這台機器一次只跑一個 build（共用的 build 鎖）。
-->

## 1. 先寫測試

- [x] 1.1 `SeriesExceptionsSpecDocsTests`：requirement「Stale and busy protection」的情境清單與順序（兩邊的情境各一次）、#285 之前的「Delete of a whole series (#244)」與其「adds it a second time」那句不在、兩邊各自帶來的子句各出現一次、change 已封存且 8.3／10.4 維持未完成並指向 #324／#579。驗證：在 `origin/main` 的 spec 上跑，四個測試都紅。

## 2. 合併與封存

- [x] 2.1 本 change 的 delta 寫成合併後的 requirement：以 base 為底，逐個情境依 proposal 的對照合併；「Batch undo fails part-way」與規則時段的讀法依 `Sources` 更正。驗證：與 `origin/main` 的 spec 比對，requirement 以外逐字相同；delta 帶進的 `undo_history` 字串對照 `UndoManager.description`、`DeleteUndo` 的 note。
- [x] 2.2 `restore-series-exceptions-on-delete-undo` 的 tasks 8.3、10.4 寫明跑過什麼、還欠什麼、移到哪裡（#324、#579），維持未完成；加 10.12 記下本次封存的做法。以 `spectra archive --skip-specs` 封存。
- [x] 2.3 本 change 以 `spectra archive` 封存，delta 寫入 base spec。驗證：`spectra validate --all`；1.1 的測試轉綠。

## 3. 證明

- [x] 3.1 整套 `swift test` 在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 0 failures；依（檔案、名稱）對 `origin/main` 的移除測試檢查；每個新釘選一個 mutant 看到紅。
- [x] 3.2 PR、CI 五項通過。
