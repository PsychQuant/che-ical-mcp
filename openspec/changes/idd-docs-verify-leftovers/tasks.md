<!--
沒有 [P]：每個 task 都以 build、測試或文件比對結束，這台機器一次只跑一個 build（共用的 build 鎖）。
-->

## 1. #528：release commit 合併回 main

- [ ] 1.1 以 merge commit 合併 `5547876c`；`CHANGELOG.md` 的 `[1.23.0] - 2026-11-08` 與 `git show 5547876c:CHANGELOG.md` 的同一段逐字相同，`[Unreleased]` 只留 `git log 5547876c..origin/main` 合併的條目，過時的 `[1.23.0] - 2026-11-01` 拿掉。合併帶進的 `README.md`、`README_zh-TW.md`、`plugin/README.md`、`plugin/CHANGELOG.md` 照協調者的決定處理。驗證：抽出兩邊的 `[1.23.0]` 一段比對；`git merge-base --is-ancestor v1.23.0 HEAD` 成立。
- [ ] 1.2 發布程序加一句：摺疊 `[Unreleased]` 的 commit 要合併回 `main`。驗證：文件測試通過。

## 2. #547、#554、#555：文字

- [x] 2.1 #547：gate 第 11 步 edited-before 形狀寫出量到的結果（整串刪除、`occurrence_id`、`undo_note`、不能 undo），與 #416 一節一致；2026-11-04 那次的紀錄註明是 #428 之前的 build。
- [x] 2.2 #554 第 1 項：`calendar_name` 的描述、`update_event` 的描述與 manifest 摘要、`EventKitManager` 的註解寫成量到的例子（Exchange 沒有量）；第 2、3 項：gate (j) 的那句加上 span `future` 第一場那一格、格 E、格 M4，不加 gate 步驟；第 4 項：規格開頭一句；第 5 項：封存 proposal 的更正記在本 change 的 proposal；第 6 項：兩個註解。驗證：`ManifestParityTests` 的釘選。
- [x] 2.3 #555 第 1、2、4、9 項與 INFO：`delete_event` 的 #550 句（釘一次）、#549 只量過的兩種形狀（`leftBehind`、描述、README、規格、CHANGELOG）、三個工具只找得到 `<series>/RID=` 形狀與 echo 的條件（描述與 manifest 摘要）、span `this` 的指示只在 iCloud 量過；第 3、5 項：規格與註解；第 6、7 項：gate 的紀錄只限前三個 build、`022f2b92` 的日期；第 8 項：`EditedOccurrenceAddressWiringTests.testEachReadingOfTheDayIsBuiltFromTheEventAlone`。驗證：釘選與一個 mutant（在 `dayReadings` 的迴圈裡讀 `occurrenceDate`）看到紅。

## 3. #559

- [x] 3.1 `notFollowedTitle` 對 `.moveByCopy` 回 nil；規格的標記清單拿掉 move by copy、放進不標記的清單；`testEachFlaggedKindShowsItsOwnRecordedTitle` 拿掉那一列；`testOnlyKindsWithANotFollowedTitleAreFlagged` 加上 move by copy。驗證：先紅（count 1、flag true、title 非 nil）再綠；原本的程式就是那個 mutant。
- [x] 3.2 文字：G15（規格、兩份 README、CHANGELOG：只剩 #426 的 move，#428 的 update 是 marker）、G6／G16（`undo` 描述與 manifest 摘要加上這個限制）、G7、G9、G10、G25、G32（`undo` 描述與 manifest 的措辭，R5 不標記的情況）、G20、G31（#263 紀錄的 not-found 只在被刪的 ID 查不到時）、G22（情境的 WHEN）。第 4 節的 G19 與日曆也不見的情況寫成限制。驗證：`ManifestParityTests` 的釘選。
- [x] 3.3 測試：G11 巢狀 batch 的計數、G13 part-way 文字裡 batch 句子的位置（各一個 mutant 看到紅）；G14、G18：四個 manager 層的測試移到 `DeleteUndoFollowBatchMemberTests`，兩個改名；G28 註解；G29 兩個 spec example 的 GIVEN 改成測試建的形狀。
- [x] 3.4 封存紀錄（G8、G12、G13、G30、G33）：更正記在本 change 的 proposal。

## 4. 證明

- [ ] 4.1 整套 `swift test` 在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 0 failures；依（檔案、名稱）對 `origin/main` 的移除測試檢查。
- [ ] 4.2 PR、CI 五項通過。
