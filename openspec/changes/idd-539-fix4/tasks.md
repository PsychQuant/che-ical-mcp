## 1. 先紅

這一組到第 3 組實作 requirement「An edited occurrence's recorded slot is read both ways」的修改。

- [ ] 1.1 An edited occurrence's recorded slot is read both ways（先紅）：C1 的兩個序列（系列有時區時修改兩個場次、`clear_timezone`、經場次自己的 id 刪掉一個、刪整個系列，undo 再 undo；以及系列移動之後的過時 `/RID=`），在假的 store 上跑這個 PR 的鏈與 `main` 的鏈（`main` 自己的擷取、還原與時段檢查），斷言兩邊相同；驗證：在 `eb568983` 上紅

## 2. 整個系列刪除的 undo 回到 `main`

- [ ] 2.1 An edited occurrence's recorded slot is read both ways（回到 `main`）：擷取、還原、`Outcome` 與它們的文字與 `main` 相同；移除兩種讀法的擷取、`holdsAFloatingEdit`、`Outcome.floatingEdit`、裁定 E、`SeriesExceptionsStoreSource.isFloating`；驗證：C1 綠，矩陣每一格與 `main` 自己的擷取與還原相同
- [ ] 2.2 保留裁定 F 與 J：時段檢查的拒絕不變；C5，`/RID=` 只在 external identifier 的 origin 只有一種讀法；驗證：`held`、`heldAtWallClockOnly`、`free` 各一個測試，寫的東西是 `main` 的子集
- [ ] 2.3 預告只預測 `main` 的還原：拿掉兩種讀法的分支與原因；C3，dry run 排除同一次呼叫較早的列刪掉的場次；驗證：矩陣每一格預告與 `main` 的還原一致，C3 的形狀 dry run 與實際呼叫一致
- [ ] 2.4 被移除部分的測試改寫或移除，以（檔案、名稱）對 `eb568983` 與 `origin/main` 列出

## 3. 文字

- [ ] 3.1 `Server.swift` 的描述、manifest、README、README_zh-TW、CHANGELOG `[Unreleased]`、gate 的 #539 一節、spec 說出程式現在做的事：整個系列刪除的 undo 是 `main` 的，這個 PR 只加上 F 的拒絕、J、預告與 #541 的文字，#539 沒有修好；移除撤回時寫下、現在不成立的說法；仍成立的 LOW

## 4. 證明

- [ ] 4.1 mutant：重新啟用這個 PR 的停止、拿掉 F、拿掉預告的條件，各自紅
- [ ] 4.2 三個時區完整測試、0 失敗
- [ ] 4.3 iCloud 裝置格（新的簽章 build）：F1、D2、R2、MA、FR、S1、S2、N1 與 #538 的 sequence 1、8
