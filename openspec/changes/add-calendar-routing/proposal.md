## Why

plugin 裡每個建立事件的入口各自決定「放進哪個日曆」，而且都不讀同一份規則：`archive-event` 只讀 `default_calendar` 一個欄位，`quick-event` 與 `calendar-management` 每次都要呼叫端自己說出日曆名稱。不同習慣的資料夾（會議、教學、實驗室）因此只能靠全域規則或每次口頭指定。讓規則跟著資料夾走，是 PsychQuant/che-ical-mcp#337 的需求；使用者已於 2026-10-23 決定其中三個設計問題（見該 issue 的決定留言）。

## What Changes

- 新增 `calendar_routing` 設定：寫在 `.claude/.ical/config.yaml`，每條規則有使用者自訂的 kind 名稱、必填的 `calendar`、必填且非空的 `includes`（該 kind 涵蓋哪些事件的封閉清單），可選的 `source`（同名日曆分屬多個帳號時指定帳號）。
- 設定檔查找：從 cwd 往上找最近的 `.claude/.ical/config.yaml`，最近者勝，不合併多份；找不到再看 `~/.claude/.ical/config.yaml`；再沒有就維持現行行為。往上找在 `$HOME`、檔案系統根目錄、或 git repo 邊界停止。
- 分類由模型依 `includes` 判斷：沒有符合的規則時由呼叫端指定日曆；兩條以上符合時問使用者，不取第一條。
- 建立事件後的報告一律說明日曆怎麼決定的：`Routed to <calendar> by rule '<kind>' from <config path>`，或沒有走路由的原因（沒有設定檔、沒有符合、問過使用者）。
- 路由設定不合法時：只有 `calendar_routing` 區塊壞掉（無法解析，或某條缺 `calendar` 或 `includes`）時，回報並忽略該區塊，其他欄位照常；整份設定檔無法解析時，回報並視為不存在。指定的日曆不存在時回報並詢問，不自動建立日曆。
- 共用機制：`plugin/rules/calendar-routing.md`（單一散文契約）與 `plugin/bin/find-ical-config.sh`（決定性的查找），`archive-event`、`quick-event`、`calendar-management` 都指向它們，不各自重述。
- `default_calendar` 的意義不變：只屬於 `archive-event` 的第一層，不是路由的萬用預設；`quick-event` 也不開始使用它。只有 `default_calendar` 的既有設定行為與現在完全一樣。
- 封存狀態 `state/archives.json` 仍放在 cwd 專案的 `.claude/.ical/state/`，即使設定來自上層資料夾。
- **不改 Swift、不發 binary release**；plugin 版本與 CHANGELOG 隨之更新，marketplace 同步是另外一步。

## Non-Goals

- 第一版不做 path predicate（如 `when: path_contains`）：往上找已經讓每個資料夾有自己的一份規則。設定檔中未知的鍵會被回報並忽略，日後可以加 `when:`。
- 不在多份設定之間合併：整份取代，才說得清楚「套用的是哪一條規則」。
- 不做提醒事項清單（`remind`）的路由：提醒事項清單不是日曆，沒有人要求。
- 不改 MCP server：伺服器沒有設定檔的概念，路由是 plugin 層的 skill 行為。
- 其他 plugin 與使用者層 skill（`lecture-to-calendar`、`ntu-admin:ntu-calendar`、`ntu-rec:rec-track`）改為讀同一份路由，屬於第二階段，在各自的 repo 做，契約落地後才開始。
- 使用者全域 CLAUDE.md 的暫行段落，由使用者在本變更上線後自行換成 `~/.claude/.ical/config.yaml`。

## Capabilities

### New Capabilities

- `calendar-routing`: 設定檔查找順序、`calendar_routing` 的結構與驗證、依 `includes` 分類（無符合、多符合）、報告格式、對既有設定的向後相容。

### Modified Capabilities

- `event-source-archiving`: 需求「Project-level configuration and archive state」改變：設定檔不再只在 cwd 讀取而是依 `calendar-routing` 的查找順序；日曆選擇多一層路由，排在 `default_calendar` 之前；`default_calendar` 的語意明確為只屬於封存流程。

## Impact

- Affected specs: 新增 `calendar-routing`；修改 `event-source-archiving`。
- Affected code（皆為 markdown 與 shell）：
  - `plugin/rules/calendar-routing.md`（新）
  - `plugin/bin/find-ical-config.sh`（新）與其 shell 測試
  - `plugin/skills/archive-event/SKILL.md`（§Configuration and state、§4 Which calendar）
  - `plugin/commands/quick-event.md`
  - `plugin/skills/calendar-management/SKILL.md`
  - `plugin/CHANGELOG.md`、`plugin/.claude-plugin/plugin.json`
- 沒有 Swift 變更；沒有新的 MCP tool。
- 風險：分類是模型判斷、無法機械驗證；設定檔放在被 clone 的 repo 裡時可能把事件導向別的（含共用或訂閱的）日曆，因此每次報告都點名日曆與設定檔路徑，且路由只在既有日曆中依名稱選擇。
