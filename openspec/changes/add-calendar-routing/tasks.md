## 1. 設定檔查找 helper

- [x] 1.1 先寫 `plugin/bin/tests/find-ical-config.test.sh`（RED）：在暫存目錄樹上驗證 Config lookup walks up and the closest file wins 的五個情境（父資料夾涵蓋子資料夾、最近者勝不合併、停在 repository boundary、使用者層後備、全無）。驗證：執行測試腳本，實作前全部失敗。
- [x] 1.2 實作 `plugin/bin/find-ical-config.sh`（設定檔查找由 shell helper 決定性執行）：找到時印絕對路徑並以 0 結束，找不到時不印並以 1 結束，起點不存在時以 2 結束；專案階段停在 `$HOME`、根目錄或含 `.git` 的那一層，用實體路徑判斷。驗證：1.1 的測試腳本全部通過，且 `shellcheck` 無警告。

## 2. 共用契約

- [x] 2.1 寫 `plugin/rules/calendar-routing.md`（單一散文契約 plugin/rules/calendar-routing.md）：涵蓋 Routing rules are user-defined kinds with a required calendar and includes 的 schema 範例、分類程序（Events are classified against includes, with no match and multiple matches handled explicitly）、A routed creation reports the rule and the config file 的報告行與三種未走路由的原因文字、不合法區塊的處置（不合法的路由區塊只讓該區塊失效）、A named calendar that does not exist is reported, never created（指定的日曆不存在時回報並詢問）。驗證：內容對照 spec 逐條審閱，每個 requirement 的每個情境在契約裡都找得到對應的處理文字。
- [x] 2.2 契約內放會議資料夾的實例，對應設計決定「分類留給模型，只把查找與報告決定性化」（議程時段→會議、航班住宿→旅遊、兩者皆合的小旅行→問使用者）。驗證：實例的結論與 spec 的「One rule matches」「Two rules match」情境一致。

## 3. 入口接線

- [x] 3.1 改 `plugin/skills/archive-event/SKILL.md` 的 §Configuration 與 §4：日曆選擇順序為路由 → `default_calendar` → 推導 → 問，並寫明封存狀態留在 cwd 專案（封存狀態留在 cwd 專案）。行為對應 Project-level configuration and archive state 的修改版與 Existing default_calendar configs behave as before。驗證：對照 delta spec 的七個情境審閱文字，且文字只指向契約、不重述查找順序。
- [x] 3.2 改 `plugin/commands/quick-event.md`：建立前依契約解析日曆；沒有符合時照舊詢問，且不讀 `default_calendar`。驗證：審閱文字符合 All event-creating entry points share one resolution path 的「Two entry points give the same answer」與「quick-event ignores default_calendar」。
- [x] 3.3 改 `plugin/skills/calendar-management/SKILL.md`：「一律指定 `calendar_name`」改為先依契約解析、解析不出才指定。驗證：審閱文字只指向契約。

## 4. 實機驗證

- [x] 4.1（實際驗證範圍：helper 在暫存資料夾樹上跑；事件由本 session 依契約建立並用 `list_events` 讀回日曆；分類與報告行由只讀契約與設定檔的盲測 agent 對 10 個案例判定，`/quick-event` 為入口；`archive-event` 與 `calendar-management` 沒有各自實跑，它們只指向同一份契約）在拋棄式資料夾與名稱含 `#337` 的拋棄式日曆上，設一份含兩個 kind 的設定，三個入口各建一個符合第一個 kind 的事件。驗證：事件落在預期日曆，報告含 `Routed to` 行（All event-creating entry points share one resolution path）。
- [x] 4.2 同一設定下驗證：兩條皆符合的事件會先詢問且在回答前不建立；沒有符合的事件走入口原本的選法；`calendar_routing` 缺 `includes` 時報告點名並忽略該區塊但 `default_calendar` 仍生效；規則指定的日曆不存在時報告並詢問、沒有建立日曆；只有 `default_calendar` 的舊設定行為不變。驗證：逐項記錄實際輸出與日曆狀態；結束後依 id 刪除拋棄式日曆並用 `list_calendars` 確認清乾淨。

## 5. 發布準備

- [x] 5.1 更新 `plugin/CHANGELOG.md` 的 `[Unreleased]`；`plugin.json` 版號不動（與 binary 版號綁定，隨下次 binary release 遞增）。驗證：CHANGELOG 條目說明路由、查找順序、`default_calendar` 不變、純 plugin 變更。
- [x] 5.2 跑 `spectra validate add-calendar-routing` 與 `spectra analyze add-calendar-routing`。驗證：無 Critical 與 Warning 發現。
- [ ] 5.3 marketplace 同步與 push 停下來，用 Foresay operation 格式交給使用者；不自行 push。驗證：回報中列出待使用者執行的動作與影響範圍。
