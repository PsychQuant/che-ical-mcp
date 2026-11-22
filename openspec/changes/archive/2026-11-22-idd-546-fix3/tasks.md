## 1. 全天日期

- [x] 1.1 用 Apia 原始與位移範圍、Havana 撥回範圍的回歸測試先重現誤判，再直接檢查兩種形狀的起訖邊界。（An all-day event is read as the days it stands for）
- [x] 1.2 以 Cuba 與 America/Havana 測試時區別名，並以 Bogotá 與 Halifax 測試其他時區；拒絕其他時區的既有全天事件使用跳過午夜備援。（A date names its day when the zone skips that midnight）

## 2. 接線與文字

- [x] 2.1 校正拆出場次的測試識別碼與測試替身說明，比對實際複製閉包內的完整複製呼叫。
- [x] 2.2 補齊 manifest 句界與對應測試，同步 CHANGELOG、工具說明、README、發行檢查與規格。（An occurrence day ends at the start of the following day）

## 3. 驗證

- [x] 3.1 跑完三個時區與 Havana 的 XCTest、測試清冊比對與突變驗證。
- [x] 3.2 確認需重跑的既有量測及可隔離範圍，訂出簽署版驗證與依識別碼清理步驟。
