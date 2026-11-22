## 1. 回歸與修正

- [x] 1.1 拒絕會擴大日期的全天複製及以複製完成的搬移，保留原事件。（Copying a recognized all-day pair is refused）
- [x] 1.2 依事件時區限制校正，以秒辨識兩種形狀，並覆蓋讀取、更新規劃及刪除預覽。（An all-day event is read as the days it stands for）
- [x] 1.3 確認十個 ASCII 位元組的日期形狀，維持有午夜日期的場次搜尋視窗。（A date names its day when the zone skips that midnight; An occurrence day ends at the start of the following day）
- [x] 1.4 加入 Havana CI 步驟與刪除預覽、更新規劃的 EventKit 接線測試。

## 2. 驗證與說明

- [x] 2.1 同步工具說明、兩份 README、CHANGELOG、規格與發行驗證。
- [x] 2.2 執行三時區全套測試及 Havana 指定測試，核對移除的測試並執行突變驗證。
- [x] 2.3 訂出簽署版裝置案例、隔離範圍與依識別碼清理的驗證步驟。
