## 1. 契約與 spec

- [x] 1.1 `plugin/rules/modules/conference-recommend.md`：模式（The mode of a run is chosen from the message, then the config, then standard）、推薦（Picks come from the caller and are checked before they are applied）、比對：存標準形式，標準流程讀標準形式（方案 A，不改標記）；區塊與標準形式（A decorated event stores its standard form in one block；The standard flow reads every event in its standard form）、版面（The layer changes only the title, the location and the notes）、還原（Turning the layer off restores the standard form）、重新計算（Recomputing applies new picks per named slot）、密碼（Access codes are never written）、報告、虛構實例。驗證：對照 spec 逐條；`ConferenceRecommendDocsTests` 釘住區塊格式、模式表與 `conference.md` 的指標段。
- [x] 1.2 `conference.md` 開頭指標段改成標準形式的掛鉤；`event-modules.md` 索引加一列。驗證：`git diff` 只動這兩處，第 4、6、7 節未動（與 #498 分開，不衝突）。

## 2. 文件

- [x] 2.1 `plugin/CHANGELOG.md` 的 `[Unreleased]`。驗證：條目寫明純 plugin 變更、模式來源、比對方式、實機檢查的範圍。

## 3. 實機檢查

- [x] 3.1 以 repo 內 build 的 binary 的 `--cli`，在名稱含 `#346` 的拋棄式日曆：標準貼上、推薦層開、推薦層關；每次讀取都帶 `calendar_name`。另測為什麼還是需要標準形式的比對：伺服器的略過擋不住：以標準標題在同一起始建立，看是否被略過。驗證：推薦後的標準形式等於標準貼上；時間與提醒不變；關掉後標題、地點、notes 與標準貼上逐字相同；日曆刪除後隔一分鐘以上兩次 `list_calendars | grep -c '#346'` 為 0。
- [x] 3.1b Verify 第 1 輪之後重做（拋棄式 `#346` 日曆，讀取限定該日曆）：標題含 ` | `、兩行地點、帶 `?pwd=` 的 Zoom 連結。驗證：區塊的 item 行帶時區、地點行編碼；從讀回算出的標準形式等於標準貼上；寫入的內容沒有 `pwd`；關掉後逐字相同。
- [ ] 3.2 經由入口（`archive-event` 或 `/quick-event`）在 session MCP 上走一次：推薦後重貼不建重複、不出對照表；`conference_mode` 未設時的詢問；手機月檢視的標題。
