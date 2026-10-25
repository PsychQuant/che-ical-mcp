## 1. 實測與契約

- [x] 1.1 在名稱含 `#338` 的拋棄式日曆上建一個多日全天事件並讀回（結束日實測）。驗證：記錄讀回的第一天與最後一天，結果寫進契約檔實例（結束日以實測為準）；結束後依 id 刪除日曆並用 `list_calendars` 確認清乾淨。
- [x] 1.2 寫 `plugin/rules/event-modules.md` 與 `plugin/rules/modules/conference.md`（模組是一份契約檔，不是程式；The module applies to a conference program and can be turned off；The umbrella is one multi-day all-day event；Each scheduled item is one timed event in the conference's time zone；Parallel sessions are merged into one event；Sessions the user did not register for are created with a prefix；去重標記放在 notes，不另建狀態檔；標題或起始時間改了的場次）。驗證：對照 spec 逐條審閱，每個 requirement 的每個情境在契約裡都有對應處理文字，並含虛構議程實例。
- [x] 1.3 在 `plugin/rules/calendar-routing.md` 加一節：模組對整份輸入解析一次路由，總覽與場次共用（路由只解析一次；The calendar is resolved once through routing for the whole program）。驗證：審閱文字與 spec 一致，且 `calendar-routing` 的既有測試與 spec 不變。
- [x] 1.4 比對鍵改回「標題＋起始時間」（維護者 2026-10-25 定案；比對鍵是標題加起始時間）。驗證：契約第 6 節、spec 的去重 requirement 與兩個情境（時間更正走對照表、同日同名時段各自比對）、design、proposal 四處文字一致。
- [x] 1.5 加入預設提醒（Session events carry reminders；提醒：建立時設定、只在報名狀態改變時更新）。驗證：契約第 3、4 節、報告第 4 行、實例、spec 的 reminders requirement 與三個情境一致。
- [x] 1.6 第 3 輪驗證的修正（總覽用純日期；場次一律用 `create_event` 逐一建立；找既有集合的三步；archive-event 的例外用 ADDED，不用 MODIFIED；自己的發表；會議名稱的三個位置）。驗證：`spectra validate` 與 `spectra analyze` 無 Critical 與 Warning；`grep` 契約、spec、design、proposal 沒有真實會議名稱；`create_events_batch` 只出現在「不要用」的語境；spec 的每個新情境在契約裡有對應文字。

- [x] 1.7 第 4 輪驗證的修正（讀回比對 `*_local`、不符就警告並先問；時間寫法；邊界輸入先問；只更正部分項目的訊息；複製的文字不能形成標記；採納寫入標題、拒絕採納時記為 kept；同一天開始的另一場會議不算候選；別的日曆找到時的三個答案；`quick-event` 不再預先核准 `update_event`）。驗證：`spectra validate` 與 `spectra analyze` 無 Critical 與 Warning；契約、spec、design、proposal 對同一件事的說法一致。

## 2. 入口接線

- [x] 2.1 在 `archive-event`、`quick-event`、`calendar-management` 各加一句指向模組索引（All event-creating entry points share the module），寫成「輸入符合索引裡某個模組的觸發條件」，不寫模組名；`archive-event` 的入口段寫明議程的例外（A conference program is archived through the conference module）。驗證：審閱三處文字只指向 `rules/event-modules.md`，不重述版面、鍵或報告格式；`archive-event` 的入口段與 `event-source-archiving` 新 requirement 的每一句一致（權威訊息、部分更正、`state/archives.json` 對到總覽、估計結束時間、同日截止排除議程自己的事件、報告的更正追蹤）。

## 3. 驗證與發布準備

- [ ] 3.1（Re-pasting or correcting a program does not duplicate events）整份議程端到端驗收。已做（拋棄式日曆，2026-10-25，兩個日曆用完皆已刪除）：三天總覽讀回正確；純日期與帶非 host offset 的對照（後者差一天）；平行場次合併、`（未報名）` 前綴；提醒讀回 −15／−60 −15／無；重貼以前綴關鍵字加 ±60 天範圍找到全部事件、同日兩個「休憩」各自比對（建立 0、更新 0、未變 8）；時間更正保留 event id 與提醒；手動改過的提醒在之後的更新後保留；`conference_module: off` 由子目錄找到最近的設定檔；行事曆的全天預設提醒會加在總覽上（`create_event` 傳 `[]` 也一樣，只有 `update_event` 傳 `[]` 清得掉）。未做：邊界輸入（一天兩到三項）的詢問、只更正部分項目的訊息、讀回改用 `*_local` 後的比對、手建事件的採納與拒絕採納流程、標記以下的使用者文字在更新後保留、改名與改起日的對照表、跨日曆找到集合、報名狀態改變時的提醒、與既有事件的衝突列表、單一會議不觸發（模型判斷，日曆上無從測）。
- [x] 3.2 更新 `plugin/CHANGELOG.md` 的 `[Unreleased]`，`plugin.json` 版號不動。驗證：條目說明兩層形狀、去重標記與採納、提醒、關閉方式、`quick-event` 的權限變化、純 plugin 變更。
- [x] 3.3 `spectra validate add-conference-module` 與 `spectra analyze add-conference-module`。驗證：無 Critical 與 Warning。
