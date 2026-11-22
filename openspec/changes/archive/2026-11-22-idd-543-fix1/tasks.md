<!--
沒有 [P]：每個 task 都以 build 或測試結束，這台機器一次只跑一個 build（共用的 build 鎖）。
-->

## 1. 比對與接線

- [x] 1.1 `OccurrenceDateMatch.answer` 與 `reading`：數字不是 00:00 UTC 時照 `main`；系列讀得到、兩者都是全天時以浮動日期的 UTC 年月日比對；兩者都是計時時照 `main`；其餘兩種讀法都給才接受，只有一種給時回 `undetermined`。驗證：requirement「Occurrence date names the occurrence's shown day or its original day」的 scenario；V3 與 X3 的形狀先對 head 的邏輯紅，再綠。
- [x] 1.2 `occurrenceDateAnswer` 讀系列旗標，讀不到時傳 nil，不退回場次旗標；`occurrenceDateRefusal` 依答案選拒絕理由，兩個拒絕點都改用它。驗證：`OccurrenceDateMatchWiringTests`、`DetachedOccurrenceSpanTests` 的釘選。

## 2. 證據

- [x] 2.1 `OccurrenceDateMatchCellTests`：每一格對 `main` 與正確日子，三個例外集合與 spec 的 scenario「Every cell against main」相同。驗證：三個 process 時區都綠。
- [x] 2.2 完整 `swift test` 三個時區 0 failures；以 (檔案, 名稱) 對 `origin/main` 與 `663c81ac` 檢查移除的測試；每條新規則與新文字各一個 mutant，看到紅。

## 3. 文字

- [x] 3.1 `CHANGELOG.md`、release gate、PR body 照 verify 第一輪改寫（V5–V11、V13、V16、V19、V20、X4–X6）。驗證：內容複核。
