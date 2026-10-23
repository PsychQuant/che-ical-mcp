## Context

plugin 是純 markdown 加 shell（`plugin/skills/`、`plugin/commands/`、`plugin/rules/`、`plugin/bin/`），MCP server 沒有設定檔的概念。目前三個建立事件的入口各自決定日曆：

| 入口 | 現況 |
|---|---|
| `archive-event` | 三層：`default_calendar` → 從同類事件推導 → 問 |
| `quick-event` | 呼叫端沒指定就問 |
| `calendar-management` | 建立時「一律指定 `calendar_name`」，由呼叫端選 |

`archive-event` 說它讀「專案的 `.claude/.ical/`」，沒說是 cwd 還是往上找；沒有找到任何現存的 `.claude/.ical/config.yaml`，所以選往上找不會破壞既有設定。issue-driven-dev 的設定協定是往上找、最近者勝、遇到 `$HOME`、根目錄或 repo 邊界停止；che-apple-mail-mcp 只看 cwd。會議資料夾底下一個會議一個子資料夾，需要往上找。

PsychQuant/che-ical-mcp#337 的三個設計問題已由使用者於 2026-10-23 回覆「照建議」定案，本設計照該建議；其餘子決定仍是診斷的建議，由本變更的 review 確認。

## Goals / Non-Goals

**Goals:**

- 每個資料夾可以用一份 `.claude/.ical/config.yaml` 宣告「哪一類事件進哪個日曆」。
- 三個入口只有一條解析路徑，一份契約。
- 每次依路由建立事件，報告都說出套用的規則與設定檔。
- 既有只含 `default_calendar` 的設定行為不變。

**Non-Goals:**

- path predicate、跨設定檔合併、提醒事項清單路由、MCP server 變更。
- 其他 plugin 與使用者層 skill 的採用（第二階段，各自的 repo）。
- 自動建立不存在的日曆。

## Decisions

### 設定檔查找由 shell helper 決定性執行

`plugin/bin/find-ical-config.sh [start_dir]`：從 `start_dir`（預設 cwd）往上，在每一層檢查 `.claude/.ical/config.yaml`，印出第一個找到的路徑並以 0 結束；整個專案階段都沒有時，檢查 `~/.claude/.ical/config.yaml`；都沒有則不印任何東西並以 1 結束。專案階段在三種情況停止：到達 `$HOME`（不檢查 `$HOME` 本身，使用者層設定由第二階段處理）、到達檔案系統根目錄、或檢查完含有 `.git` 的那一層。

理由：查找是唯一能做成決定性、可測的部分；讓模型自己找會在邊界（repo 邊界、符號連結）上各入口各說各話。
替代方案：寫在散文裡讓每個 skill 自己 `ls` 往上找 → 三份重述、邊界不一致，被拒絕。

### 分類留給模型，只把查找與報告決定性化

`includes` 是自由文字，模型拿事件去比對。不嘗試把分類做成程式：不可驗證的部分用兩個機制控制風險：契約裡放實例（會議資料夾：議程時段→會議、航班住宿→旅遊、兩者皆合的小旅行→問），以及報告一律點名套用的規則。

替代方案：關鍵字或正規表示式比對 → 使用者已選擇「`includes` 是模型要比對的封閉清單」，且關鍵字會漏掉改寫；被拒絕。

### 單一散文契約 plugin/rules/calendar-routing.md

結構、查找順序（指向 helper）、分類程序、無符合與多符合的處理、報告格式、不合法時的處置，全部寫在 `plugin/rules/calendar-routing.md`。`archive-event` 的 §Configuration 與 §4、`quick-event`、`calendar-management` 只寫一句指向它，並寫入口自己的差異（`archive-event` 保留 `default_calendar` 與推導兩層）。

理由：重述三次的規格不會一起改；這正是 spec 的「所有入口共用一條解析路徑」要防的。

### 封存狀態留在 cwd 專案

`state/archives.json` 讀寫都在 cwd 專案的 `.claude/.ical/state/`，即使設定檔來自上層。理由：封存索引描述的是這個專案歸檔過哪些來源，跟著設定的位置走會讓多個子資料夾共用一份索引、互相蓋掉；現行去重行為也不變。

### 不合法的路由區塊只讓該區塊失效

`calendar_routing` 區塊無法解析，或任一條缺 `calendar` 或 `includes`：回報並忽略整個區塊，其他欄位（如 `default_calendar`）照常。整份檔案無法解析：回報並視為不存在（沿用 `archive-event` 既有的紀律）。理由：不要讓路由的筆誤連帶廢掉原本能用的 `default_calendar`，也不要讓部分有效的規則集合安靜地改變路由結果。

### 指定的日曆不存在時回報並詢問

路由只在既有日曆中依名稱選擇（有 `source` 時限於該帳號）。不自動建立日曆：路由是選擇，不是配置；且被 clone 進來的 repo 裡的設定檔不該能讓 plugin 憑空建立日曆。

## Implementation Contract

- **查找 helper**：`find-ical-config.sh [start_dir]`；找到時 stdout 是一個絕對路徑加換行、結束碼 0；找不到時 stdout 空、結束碼 1；`start_dir` 不存在時 stderr 有訊息、結束碼 2。不讀檔案內容，只做路徑查找；不跟隨符號連結到 repo 邊界之外（以 `pwd -P` 的實體路徑判斷邊界）。
- **契約檔**：`plugin/rules/calendar-routing.md`，內含 schema 範例（兩個 kind 的會議資料夾）、分類程序、報告行格式 `Routed to <calendar> by rule '<kind>' from <config path>`，以及未走路由時的三種原因文字（沒有設定檔、沒有符合、問過使用者）。
- **入口接線**：三個入口的文字指向契約，不重述；`archive-event` 的日曆選擇順序改為 路由 → `default_calendar` → 推導 → 問。
- **範圍邊界**：只動 `plugin/` 與 `openspec/`；不動 `Sources/`、`Tests/`、`mcpb/`；不新增 MCP tool。
- **驗收**：helper 的 shell 測試涵蓋最近者勝、停在 `$HOME`、停在 repo 邊界、使用者層後備、全無；在拋棄式資料夾與拋棄式日曆上實機驗證三個入口（兩個 kind 各一、兩條皆符合的詢問、無符合、壞掉的區塊、日曆不存在、只有 `default_calendar` 的舊設定）。
- **版本**：`plugin/CHANGELOG.md` 的 `[Unreleased]` 加條目。`plugin/.claude-plugin/plugin.json` 的版本**不動**：plugin 版號與 binary 版號綁定，wrapper 依它下載同版號的 GitHub Release，只升 plugin 版號會讓 wrapper 找不到 binary；版號隨下一次 binary release 一起遞增。marketplace 同步與 push 是另一步，需要使用者明確指示。

## Risks / Trade-offs

- [分類是模型判斷，無法機械驗證] → 契約放實例；報告一律點名規則；兩條符合時問，不替使用者選。
- [被 clone 的 repo 內的設定檔可能把事件導向共用或訂閱的日曆] → 報告每次點名日曆與設定檔路徑；只在既有日曆中依名稱選；EventKit 拒絕不可修改的日曆。
- [共用目錄（如 `/tmp`）裡被別人放進的設定檔把事件導向別的日曆] → helper 只接受檔案擁有者是目前使用者的設定檔，其餘跳過並在 stderr 警告；此處的 `-O` 檢查沒有自動測試（測試需要別的使用者擁有的檔案），列為手動驗證。
- [往上找可能讓父資料夾的設定套到不相關的子資料夾] → 最近者勝；在 repo 邊界停止；報告點名檔案。
- [`default_calendar` 的意義在 issue 草稿與已定案之間漂移] → 已更正 issue 草稿；spec 明寫只屬於 `archive-event`。
- [plugin 版號與 binary 版號綁定，純 plugin 變更不能單獨遞增版號] → 這個變更隨下一次 binary release 一起發出；在那之前使用者拿不到新 skill，這是接受的代價。
- [helper 的 shell 測試是否納入 CI 未確定] → 實作時先看現有 CI 設定；若沒有 shell 測試的位置，測試腳本放 `plugin/bin/tests/` 並在任務中註明手動執行方式。

## Migration Plan

沒有資料遷移：沒有現存的 `calendar_routing`，既有設定行為不變。上線為一次 plugin 版本更新；回滾是還原 plugin 版本。

## Open Questions

- 使用者層設定 `~/.claude/.ical/config.yaml` 是否也要有一個範本或指令產生？目前不做，等有人要用時再開 issue。
- 第二階段各 skill 採用契約時，是否需要共用的測試資料？契約落地後再看。
