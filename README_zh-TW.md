# che-ical-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**讓 Claude 直接操控 macOS 行事曆與提醒事項。** 一個建構在 EventKit 之上的原生 Swift MCP 伺服器 — 29 個工具涵蓋事件、提醒、標籤、批次操作、衝突偵測與復原／重做。不只是行事曆事件，連提醒事項和任務也一起管。

[English](README.md) | [繁體中文](README_zh-TW.md)

---

## 安裝

**Claude Code** — 先把這個 repo 註冊成 marketplace，再安裝 plugin。Plugin 內含 `/today`、`/week`、`/quick-event`、`/remind` slash 指令，以及一個在每次寫入事件時自動核對星期幾的 PreToolUse hook：

```bash
claude plugin marketplace add PsychQuant/che-ical-mcp
claude plugin install che-ical-mcp@che-ical-mcp
```

**Claude Desktop** — 從 [Releases](https://github.com/PsychQuant/che-ical-mcp/releases/latest) 下載最新的 `.mcpb`，雙擊安裝。

**單獨的 MCP** — 只要 29 個工具的伺服器本體，不需要 plugin 額外功能：

```bash
mkdir -p ~/bin
curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP && chmod +x ~/bin/CheICalMCP
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

首次使用時，macOS 會跳出**行事曆**與**提醒事項**的存取請求 — 點選**允許**。想從原始碼建置、就地升級，或在 SSH／launchd／VS Code 下執行？完整說明見下方 [安裝方式](#安裝方式)。

---

## 為什麼選擇 che-ical-mcp？

| 功能 | 其他行事曆 MCP | che-ical-mcp |
|------|----------------|--------------|
| 行事曆事件 | 有 | 有 |
| **提醒事項/任務** | 無 | **有** |
| **提醒事項 #標籤** | 無 | **有**（MCP 層級） |
| **多關鍵字搜尋** | 無 | **有** |
| **重複事件偵測** | 無 | **有** |
| **衝突檢測** | 無 | **有** |
| **批次操作** | 無 | **有** |
| **本地時區** | 無 | **有** |
| **來源消歧義** | 無 | **有** |
| 建立行事曆 | 部分 | 有 |
| 刪除行事曆 | 部分 | 有 |
| 事件提醒 | 部分 | 有 |
| 地點與網址 | 部分 | 有 |
| 開發語言 | Python | **Swift (原生)** |

---

## 全部 29 個工具

<details>
<summary><b>行事曆 (4)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_calendars` | 列出所有行事曆和提醒事項清單（包含 source_type） |
| `create_calendar` | 建立新行事曆。標題為 1 到 255 個字元且不能全是空白，`update_calendar` 也相同；`type` 只能是 `event` 或 `reminder`。這個上限不保證長標題留得住：曾有一輪連 255 字元的標題也在 `list_calendars` 讀不到（#449）。存提醒事項清單時回報錯誤、但清單其實已存好時，呼叫仍算成功；store 裡內容不同的欄位列在 `store_differs`，並附 `note`，用同樣參數再建一次可能會多出一份（#261）；無法確認是否已存時，清單會保留，呼叫回錯誤，說明再建之前要怎麼確認（#289）。無法復原（#273）：之後的 `undo` 會被拒絕、該筆紀錄丟棄，下一次 `undo` 復原的是在它之前記錄的操作 |
| `delete_calendar` | 刪除行事曆或提醒事項清單。無法復原：裡面的事件或提醒事項會一起刪除，之後的 `undo` 會被拒絕、該筆紀錄丟棄，下一次 `undo` 復原的是在它之前記錄的操作（#273）。`require_empty: true` 時，日曆內有任何事件（只檢查現在前後約 200 年，範圍外的事件看不到；通過時回傳 `checked_empty`、`searched_from` / `searched_to`）或清單內有任何提醒事項，就拒絕刪除（#328） |
| `update_calendar` | 重新命名行事曆或更改顏色（v0.9.0）。無法復原（#273）：之後的 `undo` 會被拒絕、該筆紀錄丟棄，下一次 `undo` 復原的是在它之前記錄的操作；要改回請再用 `update_calendar` |

</details>

<details>
<summary><b>事件 (4)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_events` | 列出事件，支援篩選/排序/限制（v1.0.0） |
| `create_event` | 建立事件（支援提醒、地點、網址、個別時區、含排除日期的重複規則） |
| `update_event` | 更新事件（含時區、重複規則、recurring span） |
| `delete_event` | 刪除事件 |

> **事件工具收到提醒事項的 ID（#260）**：`update_event`、`delete_event`、`copy_event`、`move_events_batch`、`delete_events_batch` 會回 `Event not found: <id>`（批次工具是該列的錯誤），不再讓 server 結束。沒有提醒事項權限時，EventKit 可能不會把它認成提醒事項，這時事件查詢的 Objective-C 例外會被接住，工具回報查詢失敗、事件可能還在（#288）。這是關掉種類檢查量到的，還沒有在提醒事項權限真的被拒絕的情況下跑過。種類檢查本身（`calendarItem(withIdentifier:)`）沒有包住，如果它在這種情況下 raise，process 仍可能結束（#293）。

> **重複規則排除日期（#182）**：`create_event`（以及 `create_events_batch` 的每個項目）的 `recurrence` 支援 `excluded_occurrence_dates`，建立重複事件時直接略過指定日期 — 排除以 best-effort all-or-nothing 語意套用（任一步失敗以補償刪除移除整個新系列；補償刪除本身失敗會明確回報、絕不靜默；第一個場次不可排除），一次 `undo` 即可移除整個系列（含排除）。排除的日期是被移除的場次，不是被單獨修改的場次（2026-10-05 只在 iCloud 確認過，其他來源沒有檢查），所以不會擋下這次復原；建立之後被單獨修改過的場次則會（#236）。已知限制：冪等重試時，所請求的排除日期**已全數缺席**的重複週期系列會回報 `skipped`，但既有系列上多出的排除日期（不在本次請求中的）不會被偵測。

</details>

<details>
<summary><b>提醒事項 (8)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_reminders` | 列出提醒事項，支援篩選/排序/限制、標籤解析（v1.0.0） |
| `create_reminder` | 建立提醒事項，支援到期日、標籤（v1.3.0）；到期日只給 `YYYY-MM-DD` 時建立純日期提醒（#267）；有到期日時（純日期或有時間）回應會帶 `date_sync`，`aligned` 依存好的提醒判斷（#301、#308；有時間的到期日存檔後掉了時區時，會重寫並再存一次，和 `update_reminder` 一樣）。存檔回報錯誤、但提醒其實已存好時，呼叫仍算成功；store 裡內容不同的欄位列在 `store_differs`，並附 `note`，用同樣參數再建一次可能會多出一份（#261）；save 失敗又無法確認是否已存時，提醒事項會保留，呼叫回錯誤，說明再建之前要怎麼確認（#289） |
| `update_reminder` | 更新提醒事項（含標籤、`clear_due_date`）（v1.3.0） |
| `complete_reminder` | 標記為已完成/未完成 |
| `delete_reminder` | 刪除提醒事項 |
| `search_reminders` | 多關鍵字或標籤搜尋提醒事項（v1.3.0） |
| `list_reminder_tags` | 列出所有已使用的標籤及使用次數（v1.3.0） |
| `cleanup_completed_reminders` | 一次刪除所有已完成的提醒事項，預設 dry_run 預覽（v1.7.2）；一次 `undo` 就能重建刪掉的項目（#243） |


**重複提醒（#194）：** list/search 新增 `has_recurrence`、完整公開 `recurrence_rules` 與保留日期精度的 `due`。完成回傳新增 `operation`（寫入結果）與 `next_occurrence`（confirmed/unknown/not_applicable）。請用 `operation.status` 判斷成功；舊 `is_completed` 可能反映下一筆仍未完成。查不到下一筆時不得再次完成。不同 ID 或無法確認的後繼項目回傳 unknown，並非宣稱系列結束。重複提醒完成的撤銷帶身分 guard（#204）：identifier 不再指向原 occurrence 時明確拒絕並移除該筆歷史，不會卡住 undo stack。**破壞性變更（#205）：** `completed` 在 `complete_reminder` / `list_reminders` / `search_reminders` 必須是 JSON boolean，字串或數字會被拒絕；省略或 `null` 維持原意。**破壞性變更（#207，未發布）：** 同一契約現在適用於所有 boolean 工具參數（`all_day`、`clear_*`、`include_completed`、`dry_run`、`delete_original`）。詳見[回傳契約與限制](docs/REMINDER_RECURRENCE.md)。

**提醒事項改期（#227/#235/#237）：** 量過的列裡，Reminders.app 列表顯示的是最早的時間型鬧鐘（#433），所以 `update_reminder` 用有時間的 `due_date` 改期時，start date 與每個絕對時間鬧鐘會跟著到期日一起移動（只給日期則改成純日期提醒，見下段；舊到期日沒有時間時按日曆天數移動，否則按精確的時間差）。`clear_due_date` 也會清掉 start date 並移除絕對時間鬧鐘。移動會保留原本就存在的差距，所以鬧鐘已經和到期日對不上的提醒事項，要傳 `realign_to_due: true` 來修正（搭配 `due_date`，或單獨使用以對齊目前的到期日；相對鬧鐘不動，所以提前的相對鬧鐘仍決定列表顯示的時間）：最早的絕對時間鬧鐘落在到期日上，較晚的鬧鐘維持與它的間隔；start date 設為到期日，除非它已經和到期日一致（純日期的到期日：當天任何時間；有時間的到期日：同一時刻，或當天午夜、或沒有時間）。回應的 `date_sync` 說明移動了什麼，`date_sync.aligned` 說明儲存後的提醒事項，start date 與最早的絕對時間鬧鐘是否和到期日一致（刻意設在別天的鬧鐘也會是 `false`）。浮動時區的提醒事項（例如在 Reminders.app 建立的純日期提醒）寫入有時間的到期日後，會保留明確的時區。undo 會還原 start date 與鬧鐘，位置鬧鐘也包括在內（#228）。

**完成重複提醒後的鬧鐘（#423）：** 帶位置提醒的重複提醒在完成之後，下一個場次與完成的那筆都會多一個 0 分鐘的一般相對鬧鐘（沒有位置）（iCloud 實測；沒有位置提醒、不重複或沒有完成時都不會出現，之後再完成也不會再多，鬧鐘留著或移除之後都一樣）。完成提醒只設定完成欄位；這個鬧鐘是 EventKit 或 store 在那次存檔造成 rollover 時加上的，沒有區分是哪一個。確認 rollover 之後，`complete_reminder` 會重新讀取下一個場次，把它的相對鬧鐘回報為 `next_occurrence.alarms_minutes_offsets`，這次讀回才出現、完成之前沒有的鬧鐘用 `alarms_note` 說明（別的 app 或同步寫入的鬧鐘看起來也一樣）。讀不回下一個場次，或它在這之間變了，`next_occurrence.alarms_read_back` 會是 `false` 並附 `alarms_read_back_note`，不回報鬧鐘。`next_occurrence.status` 是其他值時沒有這些欄位。不做任何寫入（這是預設：用途不明，所以沒有選擇把它刪掉）；試過的情況下，`update_reminder` 帶 `alarms_minutes_offsets` 可以移除它。它會不會響、Reminders.app 是否顯示，都沒有驗。完成的那筆會換新的 id，不會讀取。

**引數會依 schema 檢查（#448）：** 每個工具都會拒絕它不讀的鍵，以及不是宣告型別（字串、整數、數字、陣列、物件）的值，什麼都不做；字串陣列與整數陣列的元素也會檢查。訊息會列出可接受的鍵。批次的某一列出錯時只有該列失敗。已宣告的鍵帶 JSON null 時，這個檢查視同沒給，但 handler 仍可能拒絕（例如 `limit`）；沒宣告的鍵帶 null 一樣會被拒絕。

**座標、半徑、proximity 與 priority 會檢查（#473）：** `structured_location`（`create_event`、`update_event`、`create_events_batch` 的每一列）與 `location_trigger`（`create_reminder`、`update_reminder`）會拒絕 -90 到 90 以外的 `latitude`、-180 到 180 以外的 `longitude`，以及 0 或更小的 `radius`；`structured_location` 只給一個座標也會拒絕（兩個都給或都不給）。`location_trigger.proximity` 必填，而且只能是 `enter` 或 `leave`。`create_reminder`、`update_reminder` 與 `create_reminders_batch` 每一列的 `priority` 必須是 0 到 9 的整數；EventKit 拒絕了 10、-1 與 100（在 iCloud 上量過；Apple 文件寫的範圍是 0 到 9），所以在寫入任何東西之前就拒絕，不會改成邊界值；三個工具都把 JSON null 視同沒給。以前 0 或更小的半徑會變成 100 或被丟掉，只給一半的座標會被丟掉，`leave` 以外的 proximity（`Leave`、`exit`、沒給）都寫成 enter，而且都沒有訊息。批次的某一列出錯時只有該列失敗。字串陣列裡被讀成 data URL 的元素（以 `data:` 開頭、含逗號的文字）會被拒絕，訊息與字串引數的說明相同。

**會檢查 `recurrence` 的鍵（#434）：** `create_event`、`create_events_batch`、`update_event`、`create_reminder` 與 `update_reminder` 會拒絕 `recurrence` 裡 `frequency`、`interval`、`end_date`、`occurrence_count`、`days_of_week`、`days_of_month` 以外的鍵（兩個建立事件的工具另外接受 `excluded_occurrence_dates`），該項目什麼都不寫入。以前這種鍵會被忽略，所以把 `occurrence_count` 寫成 `count` 會建立一個永遠不會結束的系列。下列情況這些工具也會拒絕，該項目什麼都不寫入：`end_date` 與 `occurrence_count` 同時給；`daily` 或 `weekly` 規則帶非空的 `days_of_month`，EventKit 會存下來但不使用（iCloud 實測；`monthly` 與 `yearly` 會用，`days_of_week` 每種頻率都會用）；`recurrence` 的任何一個鍵，或讀取工具用的 `recurrence_rules`、`event_recurrence_rules`、`reminder_recurrence_rules` 放在 `recurrence` 旁邊而不是裡面。

**移動系列，以及從較後場次用 span `future`（#451）：** 系列已開始時有兩條封閉規則，在寫入任何東西之前檢查；否則已經發生過的場次會消失、被搬到從沒發生過的日子，或在過去多出來，而且 undo 無法還原（iCloud 實測）。從已經發生過的場次出發（span `all` 或從第一場用 span `future` 是第一場，從較後場次用 span `future` 是指定的那一場），`start_time` 只能改一天中的時間，日期必須是那一場自己的日期；其他任何日期，不論往前或往後，都會被拒絕。從還沒發生的場次出發，以及還沒開始的系列，早於現在的開始時間會被拒絕。從已經發生過的場次給 `recurrence`，必須保留原本的模式（頻率、間隔、`days_of_week`、`days_of_month`）並沿用原本的結束條件；系列還有之後的場次時，也可以不設結束條件、給不早於現在的 `end_date`，或不少於原本次數的 `occurrence_count`。以 `occurrence_count` 結束的系列，只有用 span `all`（或從第一場用 span `future`）、第一場沒有被刪、而且規則每個週期只有一個場次時，才能換成原本以外的結束條件；早於現在的 `end_date` 會被拒絕。要改其他欄位，請不要帶 `start_time` 與 `recurrence`；要從還沒發生的場次起移動或改規則，請用 span `future` 配該場次的 `occurrence_date`。從已經發生過的場次出發，給事件原本以外的 `timezone`，或對有時區的事件用 `clear_timezone`，也會被拒絕（#478）：store 會以新時區的牆上時間重複各場次，已發生的場次在夏令時間切換後移了一小時，以次數結束的系列還少了最後一場（iCloud 實測）；從還沒發生的場次用 span `future` 改 `timezone` 時，較早的場次保持不變（第一個場次單獨改過，或被刪除而剩下的第一個場次單獨改過時除外：那裡目前沒有任何 ID 能這樣改）；`clear_timezone` 沒有量過可行的做法。只有事件自己的時區識別碼（`item_timezone`）視為沒有改變，而且不會再寫入一次；同一時區的其他寫法（例如 `Asia/Taipei` 寫成 `ROC`）算是改變，沒有自己時區的事件（`item_timezone` 是 null）給任何時區，包括這台 Mac 的時區，也算是改變。這些規則只涵蓋 `start_time`、`recurrence`、`timezone` 與 `clear_timezone`：過去的單次事件加上規則，會從它那天起重複，在它與現在之間多出從沒發生過的場次；`clear_recurrence` 配 span `all` 會刪除第一場之後的場次（#439）；#442 與 #455 仍未解決。每兩週以上重複一次、週起始日不是週一的每週規則，如果這個週起始日把它的日子與系列第一場的星期分在兩週、而週一起算時在同一週（或反過來），就算是 `recurrence` 寫不出來的規則（重寫會變成週一，場次會差一週）：在已開始的系列上，不能從已發生的場次改它。從週二開始的隔週二不受影響；週起始日是週日時（Google 的寫法），從週二開始的隔週二四也不受影響。在這種規則上從較後場次帶 `calendar_name`，不論有沒有 `recurrence` 都會被拒絕。從較後場次用 span `future` 時，`all_day` 與 `occurrence_count` 會被拒絕，因為場次會消失；單獨的 `calendar_name` 也會被拒絕，因為它連較早的場次一起搬走。從還沒發生的場次出發，帶 `end_date` 或沒有結束條件的規則，配 `start_time` 或 `calendar_name`，只影響較後的場次（iCloud 實測）。

**系列有刪除過的場次時改時間（#503）：** 在 iCloud 上，一次改到系列中不只一個場次的開始、結束、`all_day` 或時區（span `all` 或 span `future`）時，其中單獨刪除過的場次全部會回來（時區是跨過日光節約時間分歧時），而 undo 無法再刪掉。現在只要其中有單獨刪除過的場次，或無法排除有：沒有結束日的系列、結束日在開始後約五年以上、檢查無法推算最後一場的次數型系列（帶月中日期的次數、從 29 到 31 日起的每月或每年次數、每週多天的長次數）、第一場已被刪除後用系列 id 讀到的系列，或檢查無法展開的重複規則（每次拒絕只寫出這次符合的條件），就會在寫入任何東西之前拒絕。`recurrence` 改到不只一個場次、而且改的是規則的樣式（頻率、間隔、星期或日期、次數）時也經過同一個檢查，因為沒有量過它會不會保留刪除（只量過只改 `end_date`，會保留），系列有不只一條規則時也一樣；沒有星期的每週規則算成系列原本第一場那天的星期，沒有日期的每月規則算成那天的日期。第一場單獨改過時，把它顯示的時間寫回整個系列也一樣，因為那個時間不是系列的時間。只改標題、備註、地點、`url`、鬧鐘或 `structured_location`，或只改 `end_date`，不受影響：在 iCloud 上用 span `all`、以及從較後場次用 span `future` 時，錨點前後的刪除都維持刪除（`url`、鬧鐘與 `structured_location` 經場次自己的 id 只在次數系列量過），從較後場次把只改 `end_date` 跟同帳號的行事曆一起寫也一樣。檢查能推算到結束的系列、而且改的不是 `all_day` 時，可以用 span `future` 並帶最後一個刪除場次「之後」某個沒有單獨改過的場次的 `occurrence_date`，從那裡起改時間，之前刪除的場次會維持刪除（只改開始時間有實測；只改結束、時區，或開始時間跟時區、規則一起改都沒有量過；改規則樣式時不給這條路；同時搬到另一個帳號時也不給，因為那種寫入從哪一場發出都會檢查整個系列；經第一場自己的 id 寫入時也不給）；其他系列沒有任何修改路徑能保留刪除。把整個系列搬到另一個帳號的行事曆（span `all` 的 `calendar_name`，或 `move_events_batch`）是先建立再刪除，會不會保留刪除過的場次沒有量過，所以也經過同一個檢查，找到刪除過的場次或無法排除時拒絕。從較後場次用 span `future` 搬到另一個帳號時，整個系列的場次都會檢查，不只錨點之後的。規則結束時間落在某個場次開始後不到一天的全天系列也不展開（EventKit 怎麼讀這個結束時間沒有量過）。其他來源沒有量過。

**重複規則屬於整個系列（PR #439）：** `update_event` 會拒絕對單一場次（`occurrence_date` 配 span `this`）帶 `recurrence` 或 `clear_recurrence`，也會拒絕 `clear_recurrence` 配 `occurrence_date` 與 span `future`，什麼都不寫入。從 v1.5.0 起的每個版本（iCloud 上實測 v1.22.0，其餘版本是讀各 tag 的程式碼），規則存在單一場次上會刪掉系列的其餘場次；`clear_recurrence` 配 span `future` 只留下系列第一天的一個事件；`clear_recurrence` 配 span `this` 則把該場次分離成單次事件，系列繼續重複。要改整個系列用 span `all`，要從某個場次起改規則用 span `future` 配 `occurrence_date`。要讓系列在某個場次結束，用 span `all` 與 `recurrence`，裡面帶系列完整的規則，以及該場次開始之後的 `end_date`，例如當天 23:59:59：只寫日期會在當天的場次之前就結束，之後的場次都會消失，單獨改過的也一樣（iCloud 實測）。系列已開始時，早於現在的 `end_date` 會被拒絕（#451）。`clear_recurrence` 配 span `all` 會只留下第一天的一個事件，並刪除其餘場次。`<series>/RID=<n>` 形式的 id（單獨改過的場次）會被告知系列的 id。`recurrence` 與 `clear_recurrence` 同時給也會拒絕。

**會把場次推到規則結束之後的開始時間變動會被拒絕（#509）：** 系列規則的結束是一個固定時刻，`update_event` 以新的 `start_time` 改系列其餘部分（span `all`，或會把系列拆開的 span `future`）時，規則會從新開始時間展開到同一個結束時刻，所以新開始時間落在結束之後的場次會被丟掉，回應仍是 `updated`，undo 也無法還原（iCloud 實測：結束時刻等於最後一場的開始時間時，任何往後的時間都會丟掉它；單獨刪掉最後一場就會留下這個形狀）。另外實測：跨過日光節約時間變動的時區更改（紐約的系列改成 UTC 後丟掉最後一場）、沒有指定日子的每月系列移到下個月，以及在呼叫裡原樣帶回結束時刻不變的系列規則，也都會丟場次。現在這種寫入會被拒絕、什麼都不寫，訊息會列出那個場次、結束時刻與它可能得到的最晚開始時間。結束時刻附近的場次會被列出來，單獨改過的場次以原本的時段計算；系列或這些場次讀不到、列不出來或無法定位時也會拒絕；開始時間往後移超過一年，以及有結束時刻的全天系列改開始時間或時區（全天規則的結束時刻與日子怎麼比沒有實測），也一律拒絕。結束時刻附近列不到系列的任何場次、規則有年中第幾週或位置但沒有指定日子，也一律拒絕；日子取自開始日的每月或每年系列（沒有自己的日子；只指定月份也算沒有），開始日在或將在 29、30、31 日時也一律拒絕（這種規則遇到沒有那一天的月份會跳過，檢查跟不上）；只改 `all_day` 也算移動（月底這項拒絕不論系列有沒有結束時刻都適用，#513：沒有結束的系列、以及開始日在 29 到 31 日的 `occurrence_count` 系列，本來就會被 #503 拒絕，所以新增的拒絕是：以 `occurrence_count` 結束、開始日從 28 日以前移到 29 到 31 日的系列（只改時區就可能做到，例如 1 日東京 05:00 改成洛杉磯），以及有結束的系列在呼叫裡帶了 `occurrence_count` 或沒有結束的規則；開始日在 29 到 31 日時，同一天只改時刻也算；沒有實測，這種系列請到行事曆 App 改）；經系列 ID 改整個系列、而第一場的原本時段無法確認時也一律拒絕（第一場單獨移動過時，系列物件顯示的是移動後的時間，檢查也會從原本的時段計算移動）。這幾種拒絕都請到行事曆 App 改。呼叫裡帶的 `recurrence` 以它自己的 `end_date` 檢查。要做這個移動，請在同一次呼叫用 `recurrence` 傳入系列的規則，`end_date` 不早於那個新的開始時間：在每週系列上實測所有場次都保留。系列有單獨刪掉的場次時，這樣的呼叫仍可能被 #503 拒絕。經單獨改過的場次（#416）的呼叫不能同時帶規則，所以這種拒絕改指向行事曆 App；有自己日子的規則（夠晚的結束時刻可能多出系列從沒有過的場次）、寫入起點的場次單獨移動過的系列（同樣的原因），已經有場次發生、規則也已結束的系列（#451 會拒絕較晚的結束時刻），以及經第一場被刪掉的系列（#326），也一樣指向行事曆 App。新開始時間在結束之後的拒絕會先列出結束附近的場次，再附上同樣的路線（移動超過一年或列不出來時，改說那個原因）；從結束前最後一場出發時，改指向 span `this`（指定星期的每週規則要落在規則的星期上，#454）。非全天的每日或每週系列在沒有日光節約時間的時區之間只改時區會保留時刻，不會被拒絕（每月或每年系列在任一時區的開始日落在 29 到 31 日時會被拒絕）；往前移而可能多出結束之後一場的情況，以及單獨改過、離原本時段超過一年的場次，沒有檢查。以 `occurrence_count` 結束的系列，在改開始時間的同一次呼叫帶很遠的 `end_date` 時，會因為結束時刻附近列不到場次而被拒絕（已知限制；較晚的結束只會多出場次）。

**開始時間要落在 `days_of_week` 上（#454）：** `create_event`、`create_events_batch` 與 `update_event` 對每種頻率都會拒絕不在清單上的開始時間，不只 `weekly`，什麼都不寫入。以前在 `daily`、`monthly`、`yearly` 上會多出一個規則外的第一場（iCloud 實測）。`update_event` 涵蓋呼叫裡帶的規則，以及 span `all` 與 `future` 時系列本身的規則。系列已經偏離規則時，不改變開始日的更新會放行。非 weekly 系列用 span `this` 移動單一場次不會被拒絕。「每月第一個週一」這類第 n 週規則本工具寫不出來，所以這種系列會被告知到行事曆 App 修改。

**開始時間也要落在 `days_of_month` 上（#461）：** monthly 與 yearly 規則上，`create_event`、`create_events_batch` 與 `update_event` 會拒絕不在規則 `days_of_month` 裡的開始日，規則與 `days_of_week` 相同，什麼都不寫入；呼叫不帶 `recurrence` 時，以 span `all` 或 `future` 改這種系列的開始日期會被拒絕，不論新的一天在不在清單上（移到清單上的另一天會讓同一天出現兩場）；span `all` 時訊息會給 monthly 系列量過的做法（帶上規則每一個欄位的 `recurrence` 與 `start_time`）；span `future` 時指向 span `all` 或行事曆 App；規則有工具寫不出的部分時則指向行事曆 App。用 span `this` 移動單一場次不檢查。iCloud 實測，這樣的開始日以前會變成規則外的第一場，把系列的開始日移到別天則會讓那一天變成規則的一部分。提醒事項不檢查。

**`yearly` 事件規則帶 `days_of_week` 時的 `occurrence_count`（#444）：** 在 `interval` 為 1 且沒有 `days_of_month` 的規則上，store 算的不是場次，所以 6 得到 22 個場次（iCloud 實測）。`create_event`、`create_events_batch` 與 `update_event` 會拒絕這裡的次數，連 1 也一樣，什麼都不寫入。要這些日子，請用 `monthly` 配 `interval: 12`，次數正確，但從較後場次以 span `future` 帶次數會被拒絕（#443），或改用 `end_date`。要每年一次，請用不帶 `days_of_week` 的 `yearly`。帶 `days_of_week` 的 `yearly` 規則只在開始日所在的月份重複。`interval` 大於 1 或有非空 `days_of_month` 不會被拒絕：這些情況次數是對的。提醒事項工具不變：提醒事項上的次數是正確的。

**重複規則屬於整個系列（PR #439）：** `update_event` 會拒絕對單一場次（`occurrence_date` 配 span `this`）帶 `recurrence` 或 `clear_recurrence`，也會拒絕 `clear_recurrence` 配 `occurrence_date` 與 span `future`，什麼都不寫入。從 v1.5.0 起的每個版本（iCloud 上實測 v1.22.0，其餘版本是讀各 tag 的程式碼），規則存在單一場次上會刪掉系列的其餘場次；`clear_recurrence` 配 span `future` 只留下系列第一天的一個事件；`clear_recurrence` 配 span `this` 則把該場次分離成單次事件，系列繼續重複。要改整個系列用 span `all`，要從某個場次起改規則用 span `future` 配 `occurrence_date`。要讓系列在某個場次結束，用 span `all` 與 `recurrence`，裡面帶系列完整的規則，以及該場次開始之後的 `end_date`，例如當天 23:59:59：只寫日期會在當天的場次之前就結束，之後的場次都會消失，單獨改過的也一樣（iCloud 實測）。`clear_recurrence` 配 span `all` 會只留下第一天的一個事件，並刪除其餘場次。`<series>/RID=<n>` 形式的 id（單獨改過的場次）會被告知系列的 id。`recurrence` 與 `clear_recurrence` 同時給也會拒絕。

**提醒事項寫入失敗後不會再落地（#274、#459）：** 既有提醒事項或提醒事項清單的 commit 可能失敗，改動會留在做這次寫入的 store 裡，那個 store 下一次任何存檔都會把它寫進去（iCloud 實測，失敗是為了測試誘發的；沒有找到一般使用會造成這種失敗的情況）。#459 起，這些寫入（修改、完成、刪除、清單改名或換色、清單刪除，以及修改或移除既有提醒事項的 undo 與 redo）改在另一個 store 上 commit，呼叫結束就丟掉，所以失敗會跟著它一起丟掉、回一般錯誤，server 長駐的 store 不會留著它（2026-11-09 實測修改與批次的一列，其他是推論）。只寫入這次呼叫改到或指名的欄位，別處改過的其他欄位會保留，undo 之後也保留（記憶體內測試涵蓋；實機上 server 的快取已經跟上）。鬧鐘分成相對、絕對、位置三個欄位，所以 `alarms_minutes_offsets` 會保留別處加的絕對或位置鬧鐘。重複提醒事項在 server 讀到之後被別的 App 推進到下一個場次時，完成它的呼叫會被拒絕，什麼都不寫。update_reminder、keep_later_edits 合併或完成的 undo 與 redo 遇到同樣情況也會被拒絕，紀錄保留。刪除的 undo 是重新建立提醒事項，屬於建立，仍在長駐 store 上。批次呼叫共用一個這樣的 store，某一列失敗後丟掉它。同時最多 4 個；需要第 5 個的呼叫會被拒絕（`writeStoreBusy`）。那個 store 用識別碼讀不到時，回 store 錯誤，不回「找不到」。每次這類寫入多約 45 ms。建立（包括 due date 的第二次存檔，#237：回 `date_sync.aligned: false`、不是錯誤，可能落地的是呼叫者要的日期）與所有事件寫入仍在長駐 store 上；事件與事件行事曆的失敗寫入本來就不會留著。

**改提醒事項的重複規則（#354）：** `update_reminder` 接受 `recurrence`（與 `create_reminder` 相同的物件，但不含 `excluded_occurrence_dates`），用來取代提醒事項的規則；`clear_recurrence: true` 則移除規則。識別碼、完成紀錄與鬧鐘都保留。改規則**不會**移動到期日（這是預設，之後可以改）：在 iCloud 實測，每週四的提醒改成週五後，待完成的這一次仍在週四，完成之後下一次才是週五（量過的是只有一個星期幾的每週規則；其他規則是預期如此，沒有量過）。到期日不在新規則的日子上時，回應附上 `recurrence_note`；要移動就對 `update_reminder` 帶 `due_date`。回應在重新讀取存好的提醒後回報 `has_recurrence`、`reminder_recurrence_rules` 與 `due`（讀不回來時 `recurrence_read_back: false`，並附 `recurrence_read_back_note`）。所有接受 `recurrence` 的工具，`interval` 都必須是 1 到 1000、`occurrence_count` 1 到 10000：`interval` 小於 1 或介於 2^31 到 2^32，以及 `occurrence_count` 為 0 時，以前會讓 server 當掉（實測）；範圍內其餘被拒絕的值則是不合理才拒絕。以下情況在寫入前就拒絕：`recurrence` 與 `clear_recurrence` 或 `clear_due_date` 同時給；呼叫後沒有到期日卻設規則；對已完成的提醒設規則；對仍會重複的提醒 `clear_due_date`（重複的提醒必須有到期日；同時帶 `clear_recurrence` 就能變成沒有到期日的單次提醒）。復原會還原原本的規則（記憶體內已測；session MCP 上待 release gate 確認）。Reminders.app 如何顯示不在規則上的那一次，沒有驗。

**提醒事項的相對鬧鐘（#333）：** `create_reminder`、`create_reminders_batch` 的每一列與 `update_reminder` 接受 `alarms_minutes_offsets`，單位是到期前幾分鐘（正數是到期前、負數是到期後；只收 -525600 到 525600 的整數，即一年；事件工具也套用同一個範圍），所以存下來的到期日可以留在真正的時間，通知可以提早來（量過的列裡的列表，以及檢查過的那一個橫幅，顯示的是鬧鐘時間，見下）。只寫相對鬧鐘：`update_reminder` 用這份清單取代提醒事項的相對鬧鐘，`[]` 會把它們移除；絕對時間鬧鐘（#227）與位置提醒（#229）不變。這和 `update_event` 不同，`update_event` 的清單會取代所有鬧鐘。相對鬧鐘需要帶時間的到期日：提醒事項沒有到期日（鬧鐘永遠不會響），或是純日期提醒時，會拒絕並且什麼都不寫，因為 Reminders 在沒有時間的日子什麼時候觸發相對鬧鐘還沒在實機量過（EventKit 存得進去也讀得回來；#333 step 0）。循環提醒的鬧鐘預期會由 EventKit 跟著每一次重複移動，這一點還沒在實機確認（列在 release gate）。**Reminders.app 顯示的時間（#433）：** 量過的 14 列裡，列表顯示的是最早的時間型鬧鐘（相對或絕對），不是到期時間，所以到期 15:30、帶 `[15]` 的提醒顯示 15:15，帶 `[-15]` 顯示 15:45。這是對那些列的歸納，不是文件寫明的規則。存下來的到期日沒有變（`list_reminders` 讀回 15:30）。做過的那一次通知檢查（#333：到期 09:54、`[2]`）通知提前來，橫幅顯示的時間與列表相同，是 09:52，不是到期時間。到期時間沒有看到第二個橫幅，但第一個橫幅還在畫面上，不能排除有一個被它擋住。最早的時間型鬧鐘不在帶時間的到期時間上時，呼叫有帶 `alarms_minutes_offsets`、`due_date` 或 `realign_to_due` 就會有 `alarms_note` 說明；這三個都沒碰的呼叫（例如只改標題）沒有 note，純日期提醒也沒有（#267 量過 App 在純日期提醒上會繼續顯示絕對鬧鐘的時間），所以沒有 note 不代表列表顯示到期時間。量過的列表列：`[15]`、`[60]`、`[2]`、`[15, 0]`、`[0]`、`[-15]`、在到期時間或更早的絕對鬧鐘，以及 `[15]` 加到期時間的絕對鬧鐘。其他形狀都是由這些列推得的，例如 `[60, 15]`、`[15, -15]`、`[-15, -60]`、`[1440]`、晚於到期時間的絕對鬧鐘、`[-15]` 加到期時間的絕對鬧鐘（沒有 note），以及 `[15]` 或 `[0]` 加更早的絕對鬧鐘（有 note）。這些列判斷不了 `[0, -15]`：目前沒有 note，留給 release gate 第 8 步確認。顯示到期時間的那幾列都沒有早於到期的鬧鐘，多加一個到期時間的鬧鐘也沒有讓列表回到到期時間（`[15]` 加它仍顯示 15:15）；這 14 列都沒有檢查通知。Reminders.app 裡設定的「提早提醒」（Early Reminder）不一樣：手動建的那一筆讀回來是一個到期時間的絕對鬧鐘，沒有早於到期的鬧鐘，這個 server 寫不出來。保留 `alarms_minutes_offsets` 是預設，之後可以改。那 14 列是一個 iCloud 清單的列表列；`[60]` 與 `[2]` 兩列來自更早的另一個拋棄式清單（#333）。沒有檢查：詳細面板、其他裝置、跨到別天的 offset（`[1440]`）、`[-15]` 什麼時候響、過去的到期時間、已完成的提醒，以及 `update_reminder` 會不會保留 App 裡設定的 Early Reminder。回應以 `alarms_minutes_offsets`（到期前幾分鐘）列出讀回的相對鬧鐘；和要求的不同時附上 `alarms_differ` 與 `alarms_note`（顯示的 note 也成立時，兩件事都說）。帶 `alarms_minutes_offsets` 的呼叫（`create_reminder`、批次的一列、`update_reminder`）在存檔後讀不回提醒事項，或建立時 `store_differs` 列出 `alarm count` 時，回應不列 `alarms_minutes_offsets`，改回 `alarms_read_back: false` 與 `alarms_read_back_note`。`update_reminder` 沒帶 `alarms_minutes_offsets`、但動到到期日（`due_date` 或 `clear_due_date`），而存好的提醒事項變成只有日期或沒有到期日時，相對鬧鐘會留著，回應附上 `alarms_note`：說明留下幾個、沒有到期日就永遠不會響或只有日期時何時觸發尚未量測，以及用 `alarms_minutes_offsets: []` 移除（`clear_due_date` 之後的數目取自存檔後的物件，沒有重新讀取；`due_date` 讀回失敗時沒有這個 note，`date_sync.aligned` 是 `false`）；略過的重複建立會得到 `alarms_applied: false`。復原這次更新會還原原本的鬧鐘，位置鬧鐘也包含在內。記憶體內測過的是：還原本身，以及 #236 的檢查依值比對鬧鐘（別處改過時會點名 `alarms`）；同步後實際 store 讀回的樣子待 release gate 確認。

**會檢查 `create_reminders_batch` 每一列的鍵（#441）：** 一列帶了 `title`、`notes`、`due_date`、`priority`、`calendar_name`、`calendar_source`、`tags`、`alarms_minutes_offsets` 以外的鍵時，該列失敗、什麼都不寫入，其他列照常處理。以前這種鍵會被忽略，所以列上帶 `recurrence` 建出來的提醒不會重複。`recurrence` 與 `location_trigger` 要用 `create_reminder`。

**純日期提醒事項（#267）：** `create_reminder`、`create_reminders_batch`、`update_reminder` 的 `due_date` 只給日期（`2026-10-18`）時，會寫成純日期提醒：有日期、沒有時間，和在 Reminders.app 建立的一樣；讀回時 `due.time` 是 `null`。`update_reminder` 會把 start date 設為那一天（原本刻意設在別天的也一樣），並移除絕對時間鬧鐘，因為 Reminders.app 顯示的是最早一個絕對時間鬧鐘，留著它就會繼續顯示時間（已在實機確認）；相對鬧鐘與位置鬧鐘保留，`date_sync.absolute_alarms_removed` 會回報移除了幾個。有時間的提醒事項給它同一天的日期，就是把時間拿掉。帶時間的到期日行為不變。只給日期的 `create_reminder`（以及 `create_reminders_batch` 建立成功的每一列）會讀回存好的提醒並回傳 `date_sync`，和 `update_reminder` 一樣：到期日讀回時帶了時間、讀回時不見了，或提醒無法重新讀取時，`date_sync.aligned` 為 `false`（#301）。`update_reminder` 寫入的到期日讀回時不見了，同樣得到 `aligned: false`；以前這種情況不回報 `aligned`。在 `list_reminders` 裡，純日期提醒要等那一天在主機時區結束才算逾期；`list_reminders` 與 `search_reminders` 的 `due_date` / `due_date_local` 則是那一天主機時區的 00:00（#297）。

**提醒事項自身的時區（#241）：** `list_reminders` 與 `search_reminders` 以 `item_timezone` 回報提醒事項自己存的時區（時區識別碼，通常是 IANA；固定位移的時區會是 `GMT+0800` 這種寫法）；沒有存時區的提醒為 `null`，包括浮動的定時提醒、純日期提醒與沒有到期日的提醒（浮動定時提醒是 `item_timezone` 為 null 且 `due.time` 有值）。每筆提醒的 `timezone` 是主機時區，也就是 `*_local` 字串所用的時區，不是提醒事項自己的時區。

</details>

<details>
<summary><b>進階功能 (10)</b> ✨ v0.3.0+ 新增</summary>

| 工具 | 說明 |
|------|------|
| `search_events` | 多關鍵字搜尋事件，支援 AND/OR 匹配 |
| `list_events_quick` | 快速捷徑：`today`、`tomorrow`、`this_week`、`next_7_days` 等 |
| `create_events_batch` | 一次建立多個事件（支援個別時區） |
| `check_conflicts` | 檢查指定時間範圍是否有重疊事件 |
| `copy_event` | 複製事件到另一個日曆；`delete_original` 時以 `move_events_batch` 的方式搬移（循環事件會被拒絕）。單純複製的 `undo` 會刪掉複本，複本之後被改過則拒絕（#273） |
| `move_events_batch` | 原地把事件搬到另一個日曆，保留循環規則與與會者；循環事件用 `span` / `occurrence_dates`（#226） |
| `delete_events_batch` | 依 ID 或日期範圍刪除事件，支援預覽模式（v1.0.0） |
| `find_duplicate_events` | 跨日曆查找重複事件（v0.5.0） |
| `create_reminders_batch` | 一次建立多個提醒事項（v0.9.0）；每一列可能帶 `store_differs` 與 `note`，和 `create_reminder` 一樣（#261）；save 失敗又無法確認的列會保留，其錯誤說明再建之前要怎麼確認（#289） |
| `delete_reminders_batch` | 批次刪除多個提醒事項（v0.9.0）；一次 `undo` 會重建這次刪除的提醒事項（#243） |

**搬移事件（#226）：** 搬移是直接改事件所屬的日曆，循環規則、與會者等所有欄位都會保留。在同一個 iCloud 帳號內 ID 不變，在 Google 帳號內會改變，跨帳號也會改變，所以請看每筆結果的 `id_changed` 與 `new_event_id`（#435）。ID 改變時，該事件較舊的 undo 紀錄會跟著改，搬移的 undo 也會回報新的 ID。循環事件用 `span: this`（預設）只搬 `occurrence_dates` 指定的那一次，該次會變成單一事件；`span: all` 搬整個系列；循環事件沒給日期會被拒絕。原地搬移失敗時才改成複製再刪除原事件，但有循環規則或與會者的事件會被拒絕。每筆結果回報 `method`（`in_place` / `copied` / `split` / `unchanged`）與未保留的欄位 `not_carried_over`。

**修改後的 ID（#268）：** `update_event` 與 `update_reminder` 回報的是儲存之後的 ID。ID 只在三種情況改變：`calendar_name` 指向另一個帳號的日曆或清單（事件部分依 #226 的實機結果；改單一場次時指定新的日曆會被拒絕，因為那會搬動整個系列）、`update_event` 從後面的場次以 `span: "future"` 切出新系列（回報新系列的 ID，用單獨改過的場次自己的 ID 時也一樣），以及首場被刪除後，用剩下的第一個場次（單獨改過）自己的 ID 搭配 span `all` 或 `future`（剩下的場次會得到新的 ID）。`id_changed` 說明它和你傳入的 ID 是否不同，只有改變時才會出現的 `previous_id` 是你傳入的 ID。只改單一場次（`occurrence_date`、span `this`）時，`id` 是系列的 ID，另附 `occurrence_id`，即那個場次自己的 ID。

**用場次自己的 ID 寫入（#416）：** 單獨改過的場次有自己的 ID（在 iCloud 上是系列 ID 後面接 `/RID=` 和一個數字）。透過這個 ID，span 的效果取決於場次的位置：

- span `this` 修改或刪除該場次。它不接受會改變日曆的 `calendar_name`、`recurrence` 或 `clear_recurrence`：這些會動到整個系列，所以會被拒絕。經系列 ID 加 `occurrence_date` 與 span `this` 寫新的 `calendar_name` 也一樣（#426）。
- `update_event` 搭配 span `all` 或 `future` 時，透過這個 ID 可以寫 `title`、`notes`、`location` 與 `recurrence`（第一個場次被刪除後，span `all` 不能寫 `recurrence`）。也可以寫 `start_time`、`end_time`、`all_day: true`、鬧鐘、`timezone`、`url` 與 `structured_location`（#428），但只限在 iCloud 上量過的形狀，以下條件要同時成立：有時間的系列、每週重複、每週至多一天；每次呼叫只帶其中一個欄位，或 `start_time` 加 `end_time`，不帶其他欄位；`start_time` 與 `end_time` 只能改當天的時刻，開始與結束都留在原本的日期；該場次仍在原本的開始時間，和沒改過的場次只差在標題、備註、地點或鬧鐘；鬧鐘只在它的鬧鐘與系列相同時可寫；`timezone`、`url` 與 `structured_location` 只限以次數結束、第一個場次還在、沒有其他單獨改過場次的系列；span `future` 時以上每個欄位都要是這種系列。系列已開始時，這些寫入照已開始系列的規則（#451）檢查，經場次自己的 ID 或經系列 ID 都一樣（#471、#478 合併後在 iCloud 實測）；從已發生的場次寫 `timezone` 由 #478 的檢查拒絕。第一個場次被刪除後，從剩下的第一個場次寫 `all_day: true` 會被拒絕。經它寫過日期之後，它的 `/RID=` 留在原本的時段（實測），所以之後經它的日期寫入都會被拒絕。`all_day: true` 只能用 span `all`、且第一個場次還在時寫（span `future` 時 #451 會拒絕，這裡也先拒絕）。經它寫 `all_day: true` 後無法經它改回：`all_day: false` 會被拒絕，全天系列的日期寫入也會被拒絕。其他都會被拒絕、不寫入任何東西，即使是沒有改變什麼的欄位（例如 `all_day: false`）。其餘請用 span `this` 或系列 ID，見下。
- `update_event` span `future` 從該場次起更新。若該場次在系列中段，系列會在此結束並另起一個新系列，可能重發邀請；`id_changed` 會回報。
- `update_event` span `all`：該場次是剩下的第一個場次時，會更新所有場次。若前面還有場次，這個呼叫會把系列切開，所以會被拒絕、不寫入任何東西；請改用 `list_events` 顯示的系列第一個場次（以原本的日期為準）的 `id`。首場被刪除的系列，除非剩下的第一個場次也被單獨改過，否則不支援更新整個系列（#326）；剩下的做法是從較後面的場次起用 span `future`，或逐場用 span `this`。
- 寫入與該場次現有值相同的值，兩種 span 都會被拒絕：它不會傳到其他場次，呼叫卻會回報 `updated`（實測）。請拿掉這個欄位，或改用系列 ID。
- 會另起新系列的寫入（從後面的場次用 span `future`，或首場被刪除後，從剩下的第一個場次用任一種 span），在該場次有自己的地點、鬧鐘、時區、全天設定、忙碌狀態或座標時會被拒絕，因為新系列會帶上它的地點與鬧鐘（實測）。寫入 `location` 會取代文字形式的地點。
- 新 `recurrence` 的 `days_of_week` 比對的是該場次原本的星期，所以從移到別的星期的場次，寫它現在顯示的星期會被拒絕。從較後場次用 span `future` 時，`occurrence_count` 會被拒絕，經系列 ID 也一樣，因為 store 從原本的第一場算起（從第三場寫 6 次只有 4 次，#443）；請改用 `end_date`。
- 系列 ID 就是 `list_events` 顯示的、沒有單獨改過的場次的 `id`。搭配 span `all` 時，系列裡有單獨改過的場次也能寫其他欄位。單獨改過的場次會保留改過的內容，之後請用 span `this` 逐一改。經這個 ID 的 `clear_recurrence` 只留下系列第一個日期的一個事件，單獨改過的場次會消失。經這個 ID 改變 `all_day` 時（從第一場用 span `future` 也一樣），只要系列有單獨改過的場次就會被拒絕，因為那會讓該場次原本的時段多出一個場次。掃描看不出系列在哪裡結束（沒有結束日、結束在系列開始約五年之後，或次數上限的最後一場算不出來），或讀不到系列時，排除不了這種場次，也會被拒絕；同一次呼叫清掉重複規則時照常進行（#442）。規則有結束日的系列，這裡放行的更改接著會被 #509 拒絕，因為寫入前或寫入後它是全天系列；同一次呼叫清掉重複規則，或帶 `occurrence_count`、沒有結束的 `recurrence` 時除外。有次數上限的系列不接受 `clear_timezone`，因為它會少掉最後一場，有沒有單獨改過的場次都一樣（#455），另一個帳號的日曆沒有量測。同一帳號的日曆請用 `move_events_batch` span `all`，它會搬動整個系列。span `future` 的做法：先用 span `this` 改這個場次，再用這個 `id` 加下一個場次的 `occurrence_date` 與 span `future`；這條路不含 `all_day`、`clear_recurrence` 與 `calendar_name`，它們不會只動到後面的場次（#451），也不含沒有量測的 `clear_timezone`。
- **第一個場次改過時的系列 ID（#428）：** 第一個場次單獨改過而開始時間沒變，或第一個場次被刪除而剩下的第一個場次單獨改過時，系列沒有可儲存的物件。這時經系列 ID 的 `update_event` 與 `delete_event` span `all` 會改走該場次自己的 ID，規則同上，前提是該場次的開始時間不晚於下一場的時段、也不晚於其他場次顯示的開始時間。若晚於，經它自己的 ID 寫 span `all` 或 `future`、以 span `future` 刪除也都會被拒絕：那種存檔沒有量過。第一個場次被刪除時，span `all` 寫新的 `recurrence` 會被拒絕（經系列 ID 或該場次自己的 ID 都一樣）：它會從較後的時段另起新系列，帶規則的寫入沒有量過。`id` 維持系列 ID（另起新系列時除外），`occurrence_id` 指該場次。這個刪除會刪掉所有場次（在 iCloud 上以 5 場系列、開放式系列與另有場次改過的系列實測，事後列出七年內的事件確認）；回應會加上 `occurrence_id` 與 `undo_note`，因為它無法 undo。這個形狀下，經系列 ID 的 span `future` 仍會被拒絕；第一個場次自己的 `id` 可以用 `delete_event` span `future`。`delete_events_batch` 搭配 span `all` 時，不論以 `event_ids` 或日期範圍呼叫，系列那一列也會經該場次刪除，dry run 也會這樣顯示（#436、#427）。這個刪除無法 undo：dry run 那一列會附 `occurrence_id` 與 `undo_note`；實際呼叫會在 `through_first_occurrence` 列出它並附 `undo_note`，它不放進這次呼叫的 undo（undo 只還原其他列）；若沒有其他列被刪，這次呼叫的 undo 會像 `delete_event` 一樣被拒絕並丟棄。
- **這些拒絕拿掉的呼叫（#416）：** 從只移了時間、長度與系列相同的場次，用 span `all` 或 `future` 只帶 `start_time`，原本做得到它說的事。它維持拒絕，因為該場次有自己的時間；請用系列 ID。只剩一個場次時，因為沒有沒改過的場次可以比對，日期寫入一律會被拒絕；剩下的場次全都單獨改過時也一樣。span `this` 在那裡做得到一樣的事。
- 搭配 span `this` 或 `future` 時，`occurrence_date` 必須是該場次的日期，否則會被拒絕：它原本會被忽略，寫入從這個 ID 指的場次開始。
- `delete_event` span `future` 刪除該場次與之後的場次，所以從第一個場次呼叫會刪掉整個系列。
- `delete_event` span `all` 只會刪掉該場次，所以只要還有其他場次就會被拒絕、不刪除任何東西。要刪掉整個系列，請用系列第一個場次的 `id`：沒有 `/RID=` 時搭配 span `all`，有 `/RID=` 時搭配 span `future`（這個刪除無法 undo）。系列若可能超出掃描範圍（約五年），就算作還有其他場次。`delete_events_batch` 以 `event_ids` 呼叫時只拒絕那一列（dry run 也會顯示），其他列照常處理，同一次呼叫列出的場次不算剩餘場次，span `all` 時這些列先執行（dry run 也一樣）；以日期範圍搭配 span `all` 呼叫時，只要系列還有場次不在列表裡，那一列也會被拒絕，dry run 同樣顯示，且不計入 `deletions`（#427）。範圍裡也列到系列自己的 ID、而且系列那一列單獨就會刪除時，ID 帶 `/RID=` 的場次交給系列那一列處理，連同整個系列一起刪除，可能超出掃描範圍的系列也一樣；否則該場次那一列照 `event_ids` 的順序先執行，系列那一列再處理其餘場次。
- `move_events_batch` span `all` 在同一個 iCloud 帳號內會搬動整個系列、ID 不變，undo 會搬回來；跨帳號沒有量測。span `this` 要在 `occurrence_dates` 帶該場次自己的日期，它會以單一事件複製到目標日曆，並從系列移除；沒帶日期或帶別的日期會被拒絕，什麼都不搬動（#426）。`copy_event` 帶 `delete_original` 時拒絕這種 ID，和循環事件一樣。

以上是在 iCloud 上實測的。上面更新與刪除整個系列的路徑都經由第一個場次，在那些形狀下系列 ID 也會走到它（#428）。Google 上 #320 量到 `/RID=` 與 `isDetached` 可靠，但這些拒絕沒有在 Google 上跑過。沒有 `/RID=` 的來源（Exchange 可能如此，尚未量測）無法從 ID 列出系列其餘場次，所以 span `all` 以及 `update_event` 的 span `future` 會被拒絕，被誤報為單獨改過場次的單一事件也一樣；請用 span `this`。在 iCloud 上，系列從開始起延伸超過約五年、場次落在掃描範圍外時，也會這樣拒絕，這時系列 ID 可以更新與刪除整個系列（以約七年前開始的系列實測）。

**帶時區偏移的全天日期（#372）：** 全天事件的日期是以這台 Mac 的時區讀取的整天。`start_time` 或 `end_time` 帶有其他偏移時會先轉成這台 Mac 的時區，可能落在另一天（在 `+08:00` 的 Mac 上，`2027-04-11T23:59:59+07:00` 是 04-12，事件因此多一天）。事件仍照這樣儲存；`create_event`、`create_events_batch` 的每一筆結果與 `update_event`（呼叫後是全天事件時，只看這次給的日期）會加上 `warnings` 清單，每一項列出欄位（`field`）、它在所寫偏移下的那一天（`written_day`）、請求的日期在這台 Mac 時區下會寫成的那一天（`host_day`；重複而被略過的建立不會寫入，訊息會說既有事件沒有改變）與說明（`message`）。比較的是日期，偏移不同但同一天、或沒有偏移的值都不會警告。全天日期請不帶偏移。

**Google 行事曆上的鬧鐘（#317）：** 在放在 Google 上的行事曆量到。存檔之後大約一分鐘，絕對時間的鬧鐘讀回時變成同一時刻的相對鬧鐘；`copy_event`、或一次性事件 `delete_event` 之後的 undo 寫入的位置鬧鐘，會變成事件開始時的普通鬧鐘；回應都看不到這些。相對鬧鐘在每條路徑上都保住了，包括 `update_event` 在一次性事件上寫入的 `alarms_minutes_offsets`。Google 從頭到尾沒有列出 email 鬧鐘（量到的每個事件都是），也沒有列出沒被複製的那個事件的位置鬧鐘，雖然這台 Mac 兩者都仍讀得到；讀回事件只看得到這台 Mac 的資料，看不出 Google 那邊有什麼。絕對鬧鐘的改變與 email 鬧鐘的情形，在不是這個 server 寫入的事件上也一樣。沒有量過：Exchange 與其他帳號、帶 `delete_original` 的 `copy_event`、`move_events_batch` 的 fallback 複製與跨帳號搬移、`create_events_batch`、系列、單一場次或 batch 刪除的 undo、聲音鬧鐘。

</details>

<details>
<summary><b>復原/重做（3）</b> ✨ v1.4.0 新增</summary>

| 工具 | 說明 |
|------|------|
| `undo` | 復原最近一次有記錄的行事曆/提醒事項操作。`create_calendar`、`update_calendar`、`delete_calendar` 會記一筆紀錄，只是為了讓 `undo` 不會改去復原更早的操作：它們的 undo 會被拒絕、該筆紀錄丟棄，下一次 `undo` 復原的是在它之前記錄的操作（#273） |
| `redo` | 重做上次復原的操作。只有「完成」會再寫一次；建立、刪除、修改、搬移的 redo 什麼都不寫，回 `success: false` 並指出該用哪個工具，然後把這筆從 redo 紀錄移除（#247）。不重做這些寫入是設計如此（#295）：要重做就用原本的工具再做一次 |
| `undo_history` | 列出可復原的操作及時間戳記 |

**復原不會蓋掉之後有人做的修改（#236）：** 復原建立、修改、搬移或完成的操作之前，會重新讀取事件或提醒事項，確認復原要覆寫或刪除的內容在那次操作之後沒有被改過（搬移只看日曆；在這裡建立的循環事件還會看有沒有單獨改過的場次，查到第一個場次之後四年內；場次的任何比對欄位與系列不同就算，包括鬧鐘、時區、地點與忙碌狀態（availability）；回到系列原值的場次不算；忙碌狀態只在場次與系列都有回報時才比對，所以在只有一邊回報的行事曆上，場次自己的忙碌狀態看不出來）。已經被改回復原要寫入的值的欄位不算。日曆 app 或伺服器自己做的兩種改變不算修改，不會擋下復原，修改的復原也會把它們蓋回去：鬧鐘的音效，以及為原本沒有座標的地點補上的座標。如果有被改過，就什麼都不寫，錯誤訊息列出改過的欄位，這筆紀錄留在 `undo_history`；要把修改改回來再復原，或用 `undo` 加 `discard_id` 放棄這次復原，由做出修改的人決定。有三種 create-undo 拒絕只能選擇要不要放棄：單獨修改過的場次放不回系列；無法檢查場次的系列（`unchecked_occurrences`）之後也一樣無法檢查；系列的重複規則被縮短（`recurrence`；修改或刪除某個場次及其後的場次會造成），被切掉的部分放不回去。重做「完成」時也會以復原留下的狀態做同樣的檢查。動到循環事件的 `update_event`（改單一場次、span "future" 或 "all"、加上或移除重複規則）不能復原：`undo` 什麼都不寫，訊息說明若要改回請到行事曆修改，並丟棄這筆紀錄，讓更早的操作仍可復原（#262：這種復原以前會刪掉系列的其餘場次）。一次性事件的修改或搬移，若在復原時該事件已變成重複事件或單獨修改過的場次（搬移的本來就是單獨修改過的場次也算），也一樣拒絕；所以修改的復原與一次性事件搬移的復原不會寫入循環事件（整個系列的搬移仍會整個搬回，這是設計如此）。循環事件修改的安全復原見 #263。

**復原修改時保留之後的編輯（#265）：** 一次性事件的 `update_event`、或 `update_reminder` 的復原，因為項目在修改之後又被改過而被拒絕時，錯誤訊息現在會分開列出這次修改改了哪些欄位、之後又改了哪些欄位。之後的編輯都不在這次修改改過的範圍內時，訊息會說明；這時帶 `keep_later_edits: true` 呼叫 `undo`（先問使用者），只會還原這次修改改過的欄位，保留之後的編輯，回應會同時列出兩者。一起變動的欄位算一組：事件的開始、結束、全天、時區、鬧鐘、日曆與忙碌狀態（事件改成全天或有時間後，相對鬧鐘代表的時間就不同；日曆決定能留哪些鬧鐘與忙碌狀態）；事件的地點文字與地點（修改加上的座標算這次修改改的）；提醒事項的到期日、開始日、鬧鐘、重複規則、完成狀態與清單。修改沒有改到任何復原會還原的欄位時，不提供合併。之後的編輯落在這次修改改過的範圍內時照舊拒絕，不在這些組裡的欄位也一樣。不帶這個參數時行為不變：復原寫回每個記錄的欄位，之後只要有任何編輯就拒絕。其他種類的復原不受影響，改到循環事件的修改照舊拒絕（#263），也不能與 `discard_id` 或 `restore_available` 一起用。合併的寫入只有單元測試與原始碼結構測試涵蓋，沒有在裝置上跑過（復原有狀態，要等 release gate 在 session MCP 上驗）。

**首場被刪除的系列（#326、#335）：** 它的 id 仍然可用。工具會改由系列最早的剩餘場次找到它，搜尋範圍是系列第一個開始時間的前一天起往後 1460 天、在系列所在的行事曆裡：移動、複製、刪除，以及更新單一場次（`occurrence_date`、span `this`）都可以，這些移動與刪除的 undo 也會還原系列。如果剩餘場次之前有被單獨編輯過的場次，更新整個系列、或從某個日期起刪除或更新，會被拒絕並說明原因。如果所有剩餘場次都在系列第一個開始時間的 1460 天之後才開始，就找不到任何場次，id 會回 `Event not found`：不擴大搜尋就無法和已經沒有場次的系列分辨，這種系列請在行事曆 App 裡修改。

**刪除場次的復原與忙碌狀態（#244、#245）：** `delete_event` 刪掉循環事件的單一場次（span "this"）後復原，那個場次會以一次性事件回到原本的時間，不會回到系列裡（EventKit 做不到），系列的絕對時間鬧鐘會變成該場次開始時的鬧鐘（復原訊息會說明，批次只說一次）。span "future" 的刪除只有在從系列第一個場次開始、把整個系列刪掉時，復原才會重建系列；其他情況（系列還留下一部分、從最後一個場次開始刪、或 id 指的是單獨修改過的場次）什麼都不寫，訊息說明若要找回請到行事曆處理，並丟棄這筆紀錄。含有這種刪除的 `delete_events_batch`，復原會在還原任何事件之前就拒絕。整個系列的刪除（上述 span "future" 的情況，或 span "all"）復原時，會先依重複規則重建系列，再還原檢查視窗內的例外（最長四年：從刪除前三年開始，若第一個場次前一天比較晚就從那天開始；規則較早結束時視窗往前移：有結束日的規則讓視窗結束在結束日後一天，以次數結束的規則（取它最晚可能的時段）只把視窗往前移、不截斷視窗尾端；以次數結束、而刪除前後的視窗又晚於第一個場次時，另外也記錄從第一個場次起的四年。所以很久以前開始的系列，檢查的是刪除前後的場次；三年內開始的系列，視窗和以前一樣從第一個場次開始，#319）：之前單獨刪掉的場次維持刪除，單獨修改過的場次以獨立的一次性事件回來、不再屬於系列（#285）；復原訊息會說明各有幾個。視窗兩側各一年也會一併列舉，並依規則時段判斷，所以被移出視窗的編輯場次仍會以一次性事件回來；移得超過一年的不會還原、其時段算成已刪除，訊息會說明。若紀錄與重建的系列對不上，就不套用任何例外，訊息也會說明。系列第一場永遠不會被移除：若它曾被單獨編輯或刪除，就由規則保留，訊息會說明。視窗外的例外，以及刪除當時無法列出例外的系列，仍只依規則重建，訊息也會說明。若再復原先前那次單一場次的刪除，而還原後的系列已經有該時段的場次，就什麼都不寫並說明；判斷依據是場次所屬的系列（或復原從它重建的系列）與規則給它的時段，不看標題（#321），所以同一時間有另一個同名系列時，場次仍會回來；紀錄裡沒有系列資訊時，就寫回該場次並在訊息說明。以場次自己的 id、和系列一起刪掉的單獨修改過的場次，也做同樣的檢查。`undo_history` 會把這筆紀錄列為 `Deleted event: <title> (undo recreates the series and its exceptions within the checked window (from <開始> up to <結束>): …)`（以次數結束、刪除前後的視窗又晚於第一個場次的系列，則為 `… within the checked windows (from … up to …, and from … up to …): …)`），含有這種刪除的 `delete_events_batch` 紀錄列為 `Batch (<N> operations; undo recreates <K> series and their exceptions within the checked window or windows: …)`（復原會被拒絕的批次則標示 `undo not available`）。在 iCloud 上用 `delete_event`（span "future"）與 `delete_events_batch`（span "all"）驗證過。刪除的復原現在會保留事件的忙碌狀態（空閒、忙碌…），前提是所屬日曆支援該值；上面建立與修改的檢查也會比對它。

**批次刪除以一筆紀錄復原（#185、#243、#248）：** `delete_events_batch`、整個系列的刪除、`delete_reminders_batch` 與 `cleanup_completed_reminders` 每次呼叫記一筆 undo 紀錄，只含實際刪掉的項目，並成為最新的一筆。一次 `undo` 在同一次呼叫裡逐筆存檔重建（cleanup 最多到它的 `limit`，預設 1000，或 `reminder_ids` 列出的每一筆），每筆換新的 identifier，內容是 undo 快照記錄的欄位；提醒事項的子任務沒有記錄。第一次寫入之前，會先確認每筆要放回去的行事曆或清單還在，跟還原時一樣用記錄下來的 identifier 找（別的帳號裡同名的清單不算）；有一個不在或是唯讀（要求重新整理後再讀一次仍然如此），就什麼都不寫，紀錄整筆保留，錯誤訊息會說有幾筆的行事曆或清單還在；用 `discard_id` 放棄會連那些一起丟掉。改用 `restore_available: true` 呼叫 `undo`（請先問使用者，#287），則會還原行事曆或清單還在的項目，紀錄只留下其餘項目，id 不變；回應是 `success: true`，帶 `partial: true` 與 `kept`，說明擋住保留項目的是哪一類行事曆或清單（列出項目，不寫行事曆、清單或帳號名稱）；等那些行事曆或清單回來後再 `undo` 一次就會還原它們，這時 `discard_id` 只會丟掉它們。沒有任何項目能還原時仍照舊拒絕，對其他 undo 這個參數沒有作用。若存檔仍在中途失敗，紀錄只留下還沒還原的項目，id 不變，失敗的那筆排到最後，下一次 `undo` 先還原其他項目；但若失敗那筆的行事曆或清單那時已經不在或變成唯讀，上面的檢查會整批拒絕。每次這類呼叫都會清空 redo 紀錄，而 undo 紀錄只保留最新的 50 筆。

**以 `event_ids` 搭配 span `this` 或 `future` 批次刪除（#452）：** 各列依給定的順序執行，dry run 也照同樣的順序，只有下面一個例外。某個 ID 在刪掉它、或被前面的刪除帶走的那一列之後又出現時，該列以 `Event not found: an earlier row of this call deleted it` 失敗，dry run 也一樣。span `future` 時，單獨改過的場次的 `id`（含 `/RID=<時段>`）會刪掉該場次與系列之後的場次。它在 dry run 的那一列帶 `also_deletes_later_occurrences: true` 與 `undo_note`，實際呼叫則把它列在 `following_occurrences_deleted` 並附 `undo_note`：這種刪除無法 undo，而且會讓這次呼叫的 undo 被拒絕、紀錄被丟棄，呼叫裡的每一列都不會回來。每一列都先查詢。**例外：** 同一次呼叫裡該系列較晚場次的 `id`，如果查得到、又被前面的刪除涵蓋，dry run 會顯示成 `covered_by_earlier_row: true` 並附日期，算進 `covered_by_earlier_rows`，不算進 `already_removed`，因為 dry run 看不到前面那一列的刪除。實際呼叫在查詢已找不到它時，視為已隨系列刪掉，把它算進 `already_removed`（iCloud 是這樣，2026-11-09）；store 留著它時，則把它當成自己的一列刪掉，這一列也會列在 `following_occurrences_deleted`，而 dry run 的那一列不會顯示這點。所以在實際呼叫沒有其他原因失敗的列時（查詢丟出例外也算），dry run 沒有錯誤的列數等於實際呼叫的 `succeeded` 加 `already_removed`。這只對原地改過的場次驗過；負責刪除的場次被移到較晚那一列顯示的開始時間之前時沒有驗。2001 年以前的 `/RID=` 時段是負數，不會被讀取，所以這種刪除不涵蓋之後的任何列：那一列會照常查詢，已經不在時以 not found 失敗。從來查不到、或查到的是帶重複規則的事件的場次 `id`，兩者都會失敗。沒有場次的系列 ID 需要場次日期，兩者都會失敗；某一列從系列第一個場次刪掉整個系列之後，dry run 會拒絕它、實際呼叫則查不到它。以上在 iCloud 用 `--cli` 量過（2026-11-09）：重複的一次性事件、每週系列兩個場次自己的 ID（兩種順序，以及從第一個場次開始），以及從來不存在的場次 ID；其他來源沒有量。`also_deletes_later_occurrences`、`following_occurrences_deleted` 與它們的 `undo_note` 是看 ID 裡有沒有 `/RID=`，這是 iCloud 的格式（#416），而 undo 的拒絕依的是 store 的 `isDetached`。

</details>

---

## 安裝方式

快速安裝路徑在 [README 最上方](#安裝)。這裡是完整參考 — 手動設定、原始碼編譯、權限邊界情況、就地升級，以及 CLI 模式。

### 系統需求

- macOS 14.0+（Sonoma 或更新版本，自 v1.11.0 起為完整 TCC 權限 API 所需）
- Xcode 命令列工具（僅從原始碼編譯時需要）

### Claude Desktop

**一鍵安裝（推薦）：** 從 [Releases](https://github.com/PsychQuant/che-ical-mcp/releases) 下載最新的 `che-ical-mcp-<version>.mcpb`，雙擊安裝，重新啟動 Claude Desktop。

**手動設定：** 下載 binary，再讓 `claude_desktop_config.json` 指向它。

```bash
# 升級時先 rm -f 舊 binary（macOS 26 inode-reuse 簽章雜湊錯位陷阱，#62）
rm -f /usr/local/bin/che-ical-mcp
curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o /usr/local/bin/che-ical-mcp
chmod +x /usr/local/bin/che-ical-mcp
```

編輯 `~/Library/Application Support/Claude/claude_desktop_config.json`，再重新啟動 Claude Desktop：

```json
{
  "mcpServers": {
    "che-ical-mcp": {
      "command": "/usr/local/bin/che-ical-mcp"
    }
  }
}
```

### Claude Code — plugin（推薦）

```bash
claude plugin marketplace add PsychQuant/che-ical-mcp
claude plugin install che-ical-mcp@che-ical-mcp
```

- 已經在 Claude Code 裡的話，等價的 slash 指令 `/plugin marketplace add PsychQuant/che-ical-mcp` 與 `/plugin install che-ical-mcp@che-ical-mcp` 效果相同。
- 用 **Git repo**（`owner/repo`）加 marketplace，不要用 `marketplace.json` 的原始 URL — plugin 的 `source` 是同 repo 的相對路徑（`./plugin`），只有透過 Git 加入時才解析得到。
- 也一併收錄在 `psychquant-claude-plugins` 聚合 marketplace（`claude plugin install che-ical-mcp@psychquant-claude-plugins`）；兩者提供同一個版本化 binary。
- Plugin wrapper 首次使用時，若 `~/bin/CheICalMCP` 不存在會自動下載。

### Claude Code — 獨立 MCP

```bash
mkdir -p ~/bin

# 升級時先移除舊 binary。macOS 26 kernel 可能拿舊 inode 的 stale
# code-signature cache 殺掉新 binary（執行中的舊 MCP process 可能還
# 持有那個 inode）— 這是 #62 修的升級陷阱。
rm -f ~/bin/CheICalMCP

curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP
chmod +x ~/bin/CheICalMCP

# --scope user：跨所有專案可用  ·  --transport stdio：本地 stdin/stdout
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

> **💡 提示：** 請把 binary 放在本機目錄如 `~/bin/`。雲端同步資料夾（Dropbox、iCloud、OneDrive）在同步碰到檔案時可能造成 MCP 連線逾時。

### 從原始碼編譯（可選）

```bash
git clone https://github.com/PsychQuant/che-ical-mcp.git
cd che-ical-mcp
make release && make install
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

> **⚠️ Swift 6 / Xcode 18 使用者：** 不要直接使用 `swift build` — 上游 MCP SDK 有 concurrency 錯誤（[swift-sdk#214](https://github.com/modelcontextprotocol/swift-sdk/issues/214)）。Makefile 會自動偵測並回退到 Swift 5 語言模式。

### 授予權限

首次使用時，macOS 會詢問**行事曆**和**提醒事項**存取權限。請點選**允許**。

> **⚠️ macOS Sequoia (15.x) 注意事項：** 權限對話框會歸屬於**啟動 MCP server 的父程序**，而非 binary 本身。這代表：
>
> | 環境 | 權限歸屬 |
> |------|----------|
> | Claude Desktop | Claude Desktop.app ✅（自動彈出） |
> | Claude Code 在 **Terminal.app** | Terminal.app ✅（自動彈出） |
> | Claude Code 在 **VS Code** | VS Code ❌（可能不會彈出） |
> | Claude Code 在 **iTerm2** | iTerm2 ✅（自動彈出） |
>
> **如果權限對話框沒有出現**（VS Code 常見問題），需要在 VS Code 的 Info.plist 加入行事曆使用說明：
>
> ```bash
> # 加入行事曆使用說明到 VS Code
> /usr/libexec/PlistBuddy -c "Add :NSCalendarsFullAccessUsageDescription string 'VS Code needs calendar access for MCP extensions.'" \
>   "/Applications/Visual Studio Code.app/Contents/Info.plist"
> /usr/libexec/PlistBuddy -c "Add :NSRemindersFullAccessUsageDescription string 'VS Code needs reminders access for MCP extensions.'" \
>   "/Applications/Visual Studio Code.app/Contents/Info.plist"
>
> # 重新簽名 VS Code（修改 Info.plist 後必須執行）
> codesign -s - -f --deep "/Applications/Visual Studio Code.app"
>
> # 重新啟動 VS Code，權限對話框就會出現
> ```
>
> **注意：** VS Code 更新時此修改會被覆蓋，需要在每次更新後重新執行。

### 升級既有安裝

Plugin wrapper 在**全新安裝**時會自動下載，但**不會**取代既有 binary。就地升級：

```bash
~/bin/CheICalMCP --self-update
```

會查詢 GitHub Releases 最新 tag、下載新 binary，依序檢查發布的 SHA-256、維護者的 Developer ID 簽章與 Apple 公證，全部通過才原子地取代舊版（任一檢查失敗，既有安裝都不會被動到）。若 binary 正在當 MCP server 跑，升級後請重啟 MCP host（Claude Desktop / Claude Code）讓新版本生效。手動替代方案：`rm -f ~/bin/CheICalMCP && curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP && chmod +x ~/bin/CheICalMCP`。

### CLI 模式（不啟動 MCP server）

29 個工具全都能直接從命令列呼叫，不需要跑 MCP server：

```bash
# Flag 形式：--key value
CheICalMCP --cli list_events --start_date 2026-03-29 --end_date 2026-03-30

# JSON 從 stdin
echo '{"tool":"list_calendars","arguments":{}}' | CheICalMCP --cli

# 在 Claude Code 裡透過 shell
claude -p "Run: ~/bin/CheICalMCP --cli list_events_quick --range today"
```

適合 launchd 排程、shell script、CI pipeline，以及偏好用子程序而非 MCP protocol 的 agent。TCC 權限仍需先授予 — 需要時先跑 `CheICalMCP --setup`。

---

## v1.0.0 新功能

### 彈性日期解析

所有日期參數現在支援 4 種格式：

| 格式 | 範例 | 解釋 |
|------|------|------|
| 完整 ISO8601 | `"2026-02-06T14:00:00+08:00"` | 精確日期和時間（offset 保留） |
| 無時區 | `"2026-02-06T14:00:00"` | 使用事件 `timezone`（若有），否則系統時區 |
| 僅日期 | `"2026-02-06"` | 事件 `timezone` 或系統時區的午夜；提醒事項的 `due_date` 則寫成沒有時間的純日期提醒（#267，見「純日期提醒事項」） |
| 僅時間 | `"14:00"` | 今天該時間 |

### 個別事件時區（v1.5.0）

為單一事件設定顯示時區 — 適用於多時區旅行行程。

```
「建立柏林時間 09:14 的航班」
→ create_event(title: "航班 LH123", start_time: "2026-04-08T09:14:00", timezone: "Europe/Berlin", ...)

「把飯店入住時間改成杜拜時區」
→ update_event(event_id: "...", timezone: "Asia/Dubai")

「移除事件的自訂時區」
→ update_event(event_id: "...", clear_timezone: true)
```

- **`timezone`** 接受 IANA 時區識別碼（如 `Europe/Berlin`、`America/New_York`、`Asia/Taipei`）
- 提供 `timezone` 時，無 offset 的時間字串會以該時區解釋
  - 例外是 `update_event` 的 `occurrence_date`：它指的是事件現在的某一次發生，沒有 offset 時以事件目前的時區解讀，與 `delete_event`、`move_events_batch` 相同（#383、#270）
  - 帶 offset 時照原值使用，取哪一天也以事件目前的時區算；回應的 `occurrence_start` 是比對到的那次發生的開始時間
- 事件輸出的 `timezone` 欄位和 `start_date_local`/`end_date_local` 會使用事件自身時區
- 事件輸出另有 `item_timezone`（#386）：事件自己存的時區識別碼（通常是 IANA），事件沒有存時區時（浮動事件；全天事件都是浮動的）為 `null`。這類事件的 `timezone` 會退回主機時區，所以要靠 `item_timezone` 才分得出它和存在主機時區的事件。帶 `display_timezone` 時，`*_local` 字串改用該時區，兩個欄位都不變
- 支援 `create_event`、`update_event`、`create_events_batch`
- 復原/重做會保留個別時區設定

### 鬧鐘（讀取）

事件的回應會用 `alarms` 列出事件的時間型鬧鐘（#240），格式與提醒事項讀取工具相同（#231），可以用來確認 `alarms_minutes_offsets` 寫入了什麼，也看得到指定日期的鬧鐘。適用於 `list_events`、`search_events`、`list_events_quick`（這三個工具在 `detail_level: summary` 時都不列；可用 `fields: ["alarms"]` 選取），以及 `check_conflicts`。

- `{"kind": "relative", "minutes_before": 15}`：從開始時間算起，正數是開始前、負數是開始後（與 `alarms_minutes_offsets` 同向）
- `{"kind": "absolute", "absolute_date": "...Z", "absolute_date_local": "..."}`：`absolute_date_local` 與其他 `*_local` 字串同一個時區（有 `display_timezone` 時用它）
- 先列指定日期的鬧鐘（依日期），再列相對鬧鐘（最早的在前）；沒有鬧鐘時是 `[]`。地點鬧鐘不列出。循環事件的場次回報整個系列的鬧鐘，除非該場次單獨修改過（那時回報它自己的），照 EventKit 回傳的內容

### 事件參與者與組織者資訊

事件查詢工具（`list_events`、`search_events`、`list_events_quick`、`check_conflicts`）的回應中，現在包含參與者和組織者資訊。

#### `attendees`（陣列，選填）

事件有參與者時出現。每個 attendee 物件包含：

| 欄位 | 類型 | 說明 |
|------|------|------|
| `name` | 字串或 null | 顯示名稱，不在通訊錄中時為 null |
| `email` | 字串 | 從參與者 URL 提取的電子郵件 |
| `role` | 字串 | `unknown`、`required`、`optional`、`chair`、`non_participant` 之一 |
| `status` | 字串 | `unknown`、`pending`、`accepted`、`declined`、`tentative`、`delegated`、`completed`、`in_process` 之一 |
| `type` | 字串 | `unknown`、`person`、`room`、`resource`、`group` 之一 |
| `is_current_user` | 布林值 | 是否為目前使用者 |

#### `organizer`（物件，選填）

事件有組織者時出現。包含：

| 欄位 | 類型 | 說明 |
|------|------|------|
| `name` | 字串或 null | 顯示名稱 |
| `email` | 字串 | 電子郵件 |
| `is_current_user` | 布林值 | 組織者是否為目前使用者 |

> **注意：** Attendees 和 organizer 為**唯讀**欄位（EventKit 限制）。事件沒有參與者或組織者時省略這些欄位（例如本地行事曆事件）。

### 模糊行事曆匹配

行事曆名稱現在**不區分大小寫**匹配。如果找不到，錯誤訊息是 `Calendar not found: <名稱>`，帶 `calendar_source` 時是 `Calendar '<名稱>' not found in source '<來源>'`；可用 `list_calendars` 查看名稱。

### 增強的列出/刪除工具

- **`list_events`**：`filter`（all/past/future/all_day）、`sort`（asc/desc）、`limit`
- **`list_reminders`**：`filter`（all/incomplete/completed/overdue）、`sort`（due_date/creation_date/priority/title）、`limit`
- **`delete_events_batch`**：日期範圍模式（`before_date`/`after_date`）+ `dry_run` 預覽

**`find_duplicate_events` 會檢查 `calendar_names`（#437）：** 名稱的比對方式與其他工具相同：先比對完全相同的標題，都沒有時才忽略大小寫。對不到任何行事曆的名稱、不足兩個行事曆，或不是字串陣列的值，都會被拒絕，不回傳結果，因為它只比對不同行事曆。沒給名稱時比對每個行事曆，所以這台電腦不足兩個行事曆時同樣會被拒絕。兩個帳號共用的名稱兩邊都會讀；這個工具沒有 `calendar_source`，`calendar_name`、`calendar_source` 與 `calendars` 都會被拒絕，不會被忽略。`calendars_checked` 列出實際讀到的行事曆，標題相同時附上帳號（`Work (iCloud)` 是標籤，傳入時要用 `list_calendars` 的標題）；沒給名稱時列出每個行事曆，不再是 `all calendars`。配對的每一邊都有 `calendar` 與 `calendar_source`，可分出兩個帳號；同一帳號內兩個同名行事曆，配對兩邊的內容會相同。兩個帳號共用名稱的情況只有單元測試；沒給名稱的讀取還沒在裝置上跑過。

**大範圍讀取的上限（#332）：** 1462 天以內的範圍不論有多少事件都完整讀取；跨過時鐘調整的四個日曆年是 1461 天又一小時，所以仍算窄範圍。超過 1462 天時，`list_events`、`search_events`、`check_conflicts`、`find_duplicate_events` 與依日期範圍的 `delete_events_batch` 一旦讀到超過約 200,000 個場次就會停下並回錯誤，不回傳任何結果，也不刪除任何東西。所有被讀取的行事曆合併計算，`search_events` 是在比對關鍵字之前計數。這是安全閥，不是日常上限：在 100 年的範圍約等於每年 2,000 個場次（五到六條沒有結束日的每日系列，或約 40 條每週系列），在 400 年的上限範圍約等於每年 500 個場次。每讀完一段 1460 天才檢查一次，而 EventKit 一次讀完一段，所以實際讀入量可能再超過那一段的量。`limit` 不會解除這個上限。請縮小範圍或指定一個行事曆；`find_duplicate_events` 減少 `calendar_names` 也能少讀一些，但至少留兩個，因為它只比對不同行事曆；`check_conflicts` 指定行事曆後，其他行事曆就不會檢查；`delete_events_batch` 請同時給 `after_date` 與 `before_date`，相距最多 1460 天。

超過 1462 天時，沒給 `limit` 最多回傳 500 筆，並回報 `default_limit`（`list_events` 在 `metadata.default_limit`）。`search_events` 只給 `start_date` 或只給 `end_date` 時，另一端維持距今兩年，所以這種範圍常常超過 1462 天。`limit` 最多 10000，需要更多筆時請縮小範圍。不論範圍多大，`event_count` 都是總數，只要回傳筆數少於 `event_count` 就會出現 `truncated: true`，不管是預設值還是你的 `limit` 造成的。截斷時留下哪些事件依工具而定：`list_events` 依 `sort` 取前面的；`search_events` 沒有排序參數，所以保留最接近今天的事件，依開始時間排序回傳，並在 `truncation_note` 說明。沒有截斷時，`search_events` 依讀取順序回傳，那不是時間順序。

> **重大變更**：`list_events` 和 `list_reminders` 現在回傳 `{events/reminders: [...], metadata: {...}}` 而非純陣列。

---

## 使用範例

### 行事曆管理

```
「列出我所有的行事曆」
「下週有什麼行程？」
「明天下午 2 點建立一個標題為『團隊同步』的會議」
「星期五早上 10 點加一個牙醫預約，地點是『台北市信義路 123 號』」
「刪除『已取消的會議』這個事件」
```

### 提醒事項管理

```
「列出我未完成的提醒事項」
「顯示購物清單中的所有提醒事項」
「新增提醒事項：買牛奶」
「建立一個明天下午 5 點打電話給媽媽的提醒」
「將『買牛奶』標記為已完成」
「刪除關於雜貨的提醒事項」
```

### 進階功能（v0.3.0+）

```
「搜尋包含『會議』的事件」
「搜尋同時包含『專案』和『審查』的事件」
「今天有什麼行程？」
「顯示這週的行程」
「如果我在下午 2-3 點安排會議，會有衝突嗎？」
「幫我建立接下來 3 週的週會」
「把牙醫預約複製到工作行事曆」
「把舊行事曆的所有事件移到新行事曆」
「刪除所有已取消的事件」
「找出『IDOL』和『Idol』行事曆中的重複事件」
```

### 開發體驗改進（v1.0.0）

```
「顯示我接下來 5 個事件」
→ list_events(start_date: "2026-02-06", end_date: "2026-12-31", filter: "future", sort: "asc", limit: 5)

「顯示我逾期的提醒事項」
→ list_reminders(filter: "overdue")

「預覽刪除『舊行事曆』2025 年之前的事件」
→ delete_events_batch(calendar_name: "舊行事曆", before_date: "2025-01-01", dry_run: true)

「下午 2 點建立事件」（不需要完整 ISO8601！）
→ create_event(start_time: "14:00", end_time: "15:00", ...)
```

---

## 支援的行事曆來源

支援任何同步到 macOS 行事曆 App 的行事曆：

- iCloud 行事曆
- Google 日曆
- Microsoft Outlook/Exchange
- CalDAV 行事曆
- 本機行事曆

### 同名日曆消歧義（v0.6.0+）

如果你有來自不同來源的同名日曆（例如 iCloud 和 Google 都有「工作」日曆），可以使用 `calendar_source` 參數：

```
「在 iCloud 的工作日曆建立事件」
→ create_event(calendar_name: "工作", calendar_source: "iCloud", ...)

「顯示 Google 工作日曆的事件」
→ list_events(calendar_name: "工作", calendar_source: "Google", ...)
```

如果偵測到歧義，錯誤訊息會說有多個行事曆同名，並要求帶 `calendar_source`；可用 `list_calendars` 查看來源。

---

## 疑難排解

| 問題 | 解決方法 |
|------|----------|
| Server disconnected | 重新編譯 `make release && make install` |
| 權限被拒絕 | 在系統設定 > 隱私權與安全性中授予行事曆/提醒事項存取權限 |
| 權限對話框沒有出現 | 參考[授予權限](#授予權限)中的 macOS Sequoia 解決方案 |
| **SSH 連線時權限被拒** | 參考下方 [SSH 存取](#ssh-存取) |
| 找不到行事曆 | 確認行事曆在 macOS 行事曆 App 中可見 |
| 提醒事項未同步 | 在系統設定中檢查 iCloud 同步 |

### SSH 存取

> **v1.23.0 起（[#343](https://github.com/PsychQuant/che-ical-mcp/issues/343)）**：SSH session 的環境通常沒有自己的授權，所以依照上方的規則，binary 會和在其他 host 底下一樣 re-exec 改用 CheICalMCP 自己的授權。macOS 在 SSH 下會不會採用這份授權還沒量過（[#382](https://github.com/PsychQuant/che-ical-mcp/issues/382)），所以下方步驟與 SSH 的錯誤訊息都沒有因此更改：它們寫於 re-exec 之前；方法 A 是最先該試的，re-exec 之後方法 B 可能不需要，也可能沒有幫助。

macOS TCC（透明度、同意與控制）的隱私權限是**依應用程式**授予的。SSH session 跑在 `sshd` 底下，是不同的安全環境 — 因此在本機授予 Terminal 或 Claude Code 的權限**不會**延伸到 SSH。

**方法 A — 先在本機執行一次（建議）：**
1. 在目標 Mac 上**本機**（非 SSH）執行一次 `CheICalMCP`
2. TCC 對話框出現時授予行事曆和提醒事項存取權限
3. 之後 SSH session 應能沿用該 binary 的授權

**方法 B — 授予 sshd 完整磁碟存取權限：**
1. 打開**系統設定 → 隱私權與安全性 → 完整磁碟存取權限**
2. 點 **+**，按 <kbd>⌘</kbd><kbd>⇧</kbd><kbd>G</kbd>，輸入 `/usr/sbin/sshd` 加入
3. 重新建立 SSH 連線

> ⚠️ 方法 B 會授予 `sshd` 廣泛的檔案存取權限 — 請僅在完全由你控管的機器上使用。

---

## 技術細節

- **目前版本**：v1.23.0
- **框架**：[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) v0.12.0
- **行事曆 API**：EventKit（原生 macOS 框架）
- **傳輸**：stdio
- **平台**：macOS 14.0+（Sonoma 及更新版本；post-1.10 cluster 從 13.0 上修，見 [#119](https://github.com/PsychQuant/che-ical-mcp/issues/119)）
- **工具數量**：29 個工具，涵蓋行事曆、事件、提醒事項、標籤、復原/重做、cleanup 和進階操作

---

## 版本歷史

| 版本 | 變更 |
|------|------|
| v1.23.0 | **self-disclaim 依 host 的授權決定，所有 host 同一條規則**（#343、#367）：host 對 Calendar 與 Reminders 都有完整權限就保留它的授權，被 policy 限制的 host 也保留；其他 host（含 Claude Code）會 re-exec，改用 CheICalMCP 自己的授權（由 `--setup` 建立）。banner、存取被拒訊息與 `--print-tcc-path` 給同一套步驟，並說明何時是刻意保留 host 的授權；可直接貼上的指令改用單引號。**升級**：CheICalMCP 還沒授權的話，在前景跑一次 `~/bin/CheICalMCP --setup`，再重啟 client。|
| v1.22.0 | **Claude Code 下 CheICalMCP 成為自己的 responsible process**（#343）：當 macOS 回報的 responsible process 是 Claude Code，二進位以 disclaim 屬性原地 re-exec，改由 `CheICalMCP` 的授權被檢查（Claude Code 更新也不再使它失效）；`--setup` 在任何主機都會 re-exec；其他主機維持自己的授權。`--print-tcc-path`、啟動橫幅與拒絕訊息會指出 macOS 實際檢查的 process。尚未驗證：Claude Code 為主機時經 re-exec 真的讀到行事曆。遷移步驟與同一使用者的取捨見 CHANGELOG。 |
| v1.21.0 | **跨多年的行事曆列表完整、無法使用的系列 id 會說明原因、會議模組與資料夾行事曆分流**（#285/#310/#325/#326/#335/#337/#338）：超過四年的事件列表不再被截在約 1461 天；首場被刪除的系列可再移動、複製、刪除並更新單一場次，無法使用的系列 id 會說明原因（較早的場次被單獨編輯過，或其餘場次全都被單獨編輯過）；整個系列刪除的 undo 會還原掃描範圍內的例外場次；`make verify-release-ready` 改與最新 release tag 比對。Plugin 外殼：會議議程建成一個整天總覽加每個時段一個事件，資料夾的 `calendar_routing` 規則決定行事曆。 |
| v1.20.0 | **純日期提醒事項、不覆蓋他人改動的 undo、讀取附 start date 與鬧鐘**（#231/#235/#236/#243/#247/#262/#267/#297/#299/#301/#311）：`YYYY-MM-DD` 的 `due_date` 會建立純日期提醒，純日期提醒要到當天結束才算逾期；`create_reminder` / `update_reminder` 回報 `date_sync`（含 `aligned`），`update_reminder` 新增 `realign_to_due`；`list_reminders` / `search_reminders` 回傳 `start` 與 `alarms`；提醒事項日期不論地區設定一律用西曆讀寫；`undo` / `redo` 遇到操作之後在別處改過的內容會拒絕覆蓋，動過循環事件的 `update_event` 不再 undo，場次被單獨編輯過（含改時間）的建立系列不會被刪；undo 保留位置／email／絕對時間鬧鐘、循環規則、URL、忙閒狀態與清單；批次刪除會記錄 undo。**BREAKING（行為）**：純日期 `due_date`、逾期規則、undo / redo 的拒絕、`redo` 除完成以外不寫入。 |
| v1.19.0 | **原地搬移事件、提醒事項日期同步、經驗證的 self-update**（#223/#225/#226/#227）：`move_events_batch` 改成直接換事件的日曆，不再複製再刪除，循環規則、與會者等所有欄位都保留（只有跨帳號時 ID 才改變；循環事件用 `span` / `occurrence_dates`；每筆回報 `method` / `id_changed` / `not_carried_over`；複製再刪除只作為有條件的後備）；`update_reminder` 改到期日時，start date 與絕對時間鬧鐘一起移動（Reminders.app 顯示的是鬧鐘日期），回應附 `date_sync`，`clear_due_date` 一併清掉，undo 可還原；`--self-update` 只安裝 Developer ID 簽章並經公證的 binary，共用骨架改用 `che-mcp-kit-swift` 0.2.x。**BREAKING（行為）**：循環事件沒給 `occurrence_date` 會被拒絕；`copy_event` 不再搬移循環事件；`event_ids` 中的非字串項目會被拒絕。 |
| v1.18.0 | **提醒事項 undo/redo 完整性、明確的 `discard_id`、全面嚴格 boolean**（#196/#197/#198/#199/#202/#203/#206/#207/#208/#209/#211/#212/#214/#215/#216）：undo 寫回記錄下來的 `completion_date`，redo 還原存下的時間點，不再重新推斷狀態；重複完成保留原本的時間點；`undo(discard_id)` 依 `undo_history` 的穩定 ID 明確移除卡住的頂端紀錄（已刪除的提醒事項或已失效的事件不再卡住 stack）；事件搬移記錄來源 occurrence，undo 會還原到原本的日曆；`event_recurrence_rules` / `reminder_recurrence_rules` 區分兩種格式（保留舊別名）；每個工具的 annotation 都有明確且經測試的政策，`complete_reminder`、update 與可選搬移的工具改為 `destructiveHint: true`。**BREAKING**：所有 boolean 工具參數都必須是嚴格的 JSON boolean（字串或數字會以 `<key> must be a boolean` 拒絕）。內部：提醒事項 list/search 在 actor 內先篩選、排序、限量再做 snapshot，`list_reminder_tags` 改走 snapshot seam，標籤掃描改為線性（無指數回溯），提醒事項寫入結果改為不可變的 Sendable，完成與循環歷史的方法移到專屬的 actor extension。 |
| v1.17.0 | **重複提醒讀取＋明確的完成結果＋身分 guard 的 undo＋嚴格 boolean `completed`**（#194/#204/#205）：list/search 新增 `has_recurrence`、完整 `recurrence_rules`（含 `frequency_raw_value`）與 `due` 物件；`complete_reminder` 以 `operation`（寫入結果）、`observed`（存檔後物件）與 `next_occurrence`（save 後同步觀測一次；iCloud 真機：同 ID 就地推進、完成的那筆另存新 ID）分開回報，訊息用提醒自己的時區。重複提醒完成的 undo/redo 帶身分 guard：ID 不再指向原 occurrence 時明確拒絕並**丟棄** entry（不卡 stack），找不到則保留 entry（#191）。**破壞性變更**：三個 reminder 工具的 `completed` 必須是 JSON boolean（字串／數字在任何讀寫前拒絕；省略／`null` 維持原意；`--cli` 的 JSON `null` 視同省略）。PR #195 三輪 6-AI verify、#200／#201 各自 verify、兩次真機 stdio 探測。582 tests。 |
| v1.16.1 | **型別安全＋真機驗證修復**（#184/#190/#191）：非物件 `recurrence` 改明確拒絕（原靜默丟棄）；`all_day`＋`timezone` 併用改明確拒絕（原靜默打掉 all-day 旗標、跨日界排除失效）；週期系列刪除的 undo 改由值快照重建 rule（修 EKCADErrorDomain 1010），且 undo/redo 失敗不再消費 entry。529 tests。 |
| v1.16.0 | **週期排除＋undo 完整性＋archive-event skill**（#182/#185/#180）：create_event/batch 支援 `excluded_occurrence_dates`（two-pass 建立後移除、補償刪除、第一場不可排除）；batch/series 刪除現在記 undo entry（單一 `.batch` 單元）；undo 週期事件建立現在移除整個系列；新 `archive-event` skill — 來源歸檔含更正追蹤與 `.claude/.ical/` 專案設定。514 tests。 |
| v1.15.0 | **Startup banner 偵測「versioned Claude Code host ＋ 未授權 EventKit」組合**（#175）：banner 解釋 path 旋轉並指向可操作修法；此訊號觸發時抑制矛盾的 `--setup` 建議行。另含 #173 parent-chain 診斷 polish。 |
| v1.14.0 | **Claude Desktop 工具注入 drop 修復**（#166）：`mcpb/manifest.json` `display_name` 裡一個字面 `&` 讓 Desktop 1.18286.0 從每個對話 silent-drop 整台 29-tool server（Claude Code 不受影響）；改 `&` → `and`，以失敗實機單一變數介入證實 + `ManifestParityTests` regression guard。並把 `serverInfo.name` 對齊 kebab manifest id（hygiene；已實證駁斥為主因）。**#154 姊妹批次**：csreq-mismatch TCC drift 訊號（#155，`SecCodeCheckValidity` 自我檢查 silent-denial class）、`.mcpb` 拒絕訊息不再對已 `.denied` 情況死路指向 `--setup`（#158）、macOS badge 13.0 → 14.0（#157）、swift-nio 2.96 → 2.101（#159）。454 tests。 |
| v1.13.0 | **SwiftUI SetupWindow**（#164）：互動式 `--setup` 在 #163 前景 `NSApplication` 內呈現即時狀態視窗（各實體 Grant 按鈕 + 解析出的 binary 路徑）。**Desktop 行事曆被拒修復**（#165）：`isNonInteractive` 對 GUI-app spawn 的 server 誤判 `TERM == nil` → 在 `requestFullAccess` 前 fast-fail，導致首次授權對話框永不出現；改用 `CGSession` GUI-session 訊號。429 tests。 |
| v1.12.0 | **前景 `--setup`**（#163）：互動式 `--setup` 現在跑在前景 `NSApplication` 內，EventKit 的行事曆 TCC modal 才會真的彈出（先前從裸 CLI async context silent denied）。拒絕訊息 + 啟動 banner 顯示解析出的 binary 路徑 + 可複製的 `"<path>" --setup` 命令（給埋在 `.mcpb` 裡的 binary）。 |
| v1.11.1 | **`create_event` 時間範圍驗證**（#160）：與 `update_event` 對稱 — 透過共用 `validateTimeRange` guard 拒絕反向 / 零時長的定時事件。405 tests。 |
| v1.11.0 | **TCC healing re-prompt 解鎖**（#154）：`Entitlements.plist` 加入 `personal-information.calendars` + `.reminders` — 從 pre-v1.7.1 ad-hoc 時代升級的長期安裝可能在 macOS 26.5 遇到 silent 永久行事曆拒絕（TCC row 釘在舊 cdhash、healing re-prompt 因 binary 無 entitlements 被 policy-block、所有診斷都報綠）；簽章 binary release gate 驗證兩把 key。**非互動 EventKit 強化**（#131 / #143 / #144 + #146–#150）。**BREAKING**：部署底線升到 macOS 14.0（#119）。401 tests。 |
| v1.10.0 | **TCC drift detector + 啟動 banner**（#122）：MCP-server 啟動時單次 stderr banner，含版本/路徑/PID + drift 訊號（TCC.db 路徑 per-service 不符、殘留 process）；`CHE_ICAL_MCP_NO_BANNER=1` 可關。subprocess helper pipe-deadlock 修復；所有插值 banner 值加 CWE-117 stderr-injection 防禦。 |
| v1.9.0 | **TCC access gate 重構**（#108 Phase 2, closes #109）：移除 process-lifetime `has*Access` cache anti-pattern；改用 per-call `EKEventStore.authorizationStatus(for:)`，透過新的 `AuthorizationGate` + `AuthorizationStatusSource` seam（Apple TN3153 pattern）— 狀態變化即時浮現而非 silent stale-grant 失敗。新增 `--print-tcc-path` 診斷旗標。 |
| v1.8.1 | **文件**：`mcpb/README.md` 安裝後 / 升級 TCC 權限設定指南（#108 Phase 1）。 |
| v1.8.0 | **Wire-format 一致性 wave + response-shape 參數**（#101 cluster — 3 天關 5 個 issue,全部 `Refs #N` IDD + 6-AI ensemble verify）。**Event listing response-shape 參數**（#47 / #101）：`detail_level`（`summary`/`standard`）、`fields` allow-list、`display_timezone`（嚴格 IANA）、`limit`（上限 10000）— LLM verbosity tuning。**Envelope unification**（#102 / #107,**breaking wire-format**）：移除 `list_events.metadata.returned` + `list_reminders.metadata.returned`;5 個 list/search envelope 全部 top-level `<entity>_count` pre-limit semantic;`search_reminders.result_count` → `reminder_count`;`search_reminders` 加 `limit` 對齊 `search_events`。讀 `metadata.returned` 或 `result_count` 的 MCP client 必須 update。**Validator 強化**（#101 F1–F3）：`requireOptionalInt` 改用 `Int(exactly:)` 關閉 `Int.max` DoS trap;`detail_level` / `display_timezone` validator 嚴格區分 absent vs. non-string（不 silent coerce）。**Runtime-anchored drift detection**（#103,強化 #101 M3）:`formatEventDict` ↔ `validEventFields` divergence test 改透過 `EventFormattingSource` seam + `FakeFormattableEvent`。**CHANGELOG reclass**（#106）:`result_count` rename 從 `Fixed` 移到 `Changed`（Keep a Changelog 1.1.0 — breaking rename 不算 bug fix）。**Release pipeline 修復**:pre-pack defense check 改用 `DEVELOPER_ID` cert 推得 Team ID（原本拿 SHA hash 比對 `Authority=` 人類可讀字串）。 |
| v1.7.2 | **強化 + 新功能 wave**（v1.7.1 後 30+ commits，全部 `Refs #N` IDD 紀律 + 6-AI 平行 verify）。**`--self-update`**（#49）+ **SHA-256 binary 驗證**（#98）：既存安裝升級路徑，加密保證對抗損毀的 release。**`make install-signed`**（#50）：macOS 26 上 maintainer dev TCC 流程 — 缺 Developer ID 即 fail-fast，強制 codesign 驗證。**CI test workflow**（#51）：PR 時 macos-latest 跑 `swift build` + `swift test`。**Sanitizer 強化叢集**：`escapeForStderr` 涵蓋全 C0+DEL（#73）、`sanitizeForInterpolation` 用於 executeUndo/executeRedo 的事件標題插值（#74）、CLIRunner stderr 改透過 `writeFailureLog` 走 trusted-branch carve-out（#80）、`writeFailureLog` 加 1024 char DoS 上限（#86）、`CLIError.invalidJSON` 標明 author-controlled-only 契約（#85）、`FileHandle.standardError.write` thread-safety 與 macOS PIPE_BUF=512 文件化（#70 / #94）。**Distribution polish**：陳舊 codesign 快取的 install snippet 加 `rm -f` 前置（#90 zh-TW 對齊 #62）。**Post-v1.7.1 polish**（#46 #57 #58 #60）：redo error 插值對齊、`build-mcpb.sh` step 重新編號、`Entitlements.plist` 文件化、`Makefile release-signed:` cwd 註解。**`cleanup_completed_reminders` 工具**（#21）：單一呼叫清除所有已完成 reminder，預設 `dry_run=true`。 |
| v1.7.1 | **macOS 26 簽章與公證**（#44）：發布 binary 改用 Developer ID Application 憑證簽章 + hardened runtime + `xcrun notarytool` 公證。macOS 26 收緊 TCC，ad-hoc 簽章 binary 無法觸發行事曆/提醒事項權限對話框 — 簽章+公證是讓終端使用者能授權的唯一路徑。新增 `scripts/sign-and-notarize.sh`、`Makefile` `release-signed` target、`Sources/CheICalMCP/Entitlements.plist`。**升級陷阱修復**（#62）：`make install` / `scripts/build-mcpb.sh` 寫入前先 `rm -f` 目標 binary，避免覆蓋舊 binary 時 inode 重用導致 macOS kernel 簽章雜湊快取命中錯位、新 binary 啟動時 SIGKILL（`load code signature error 2`）。**輸入驗證**（#20）：MCP 工具邊界 enforce 長度上限（title ≤255、notes ≤65535、location ≤1024）+ URL scheme allowlist（僅 http/https）。**Prompt-injection 防禦**（#20）：echo 外部資料的工具回應加上 `[UNTRUSTED CALENDAR DATA ...]` marker。**LLM-malformed integer arrays 大聲失敗**：`recurrence.days_of_week` 等遇到非法值改為 throw `ToolError.invalidParameter`，不再 silent-drop。**force-unwrap 修復**（#20）：`EKWeekday(rawValue:)!` 改為安全 `compactMap`。**`Info.plist` CFBundleVersion 同步修復**：plist 從 v1.4.1 卡住未跟進，補回與 `AppVersion.current` 一致。 |
| v1.7.0 | **事件參與者與組織者資訊**（#17）：事件回傳新增唯讀 `attendees` 陣列和 `organizer` 物件。重構共用 `formatEventDict` 方法。 |
| v1.6.0 | **`--setup` 旗標**（#13）：預授權 TCC 權限，支援 launchd/自動化環境。非互動 session 偵測（TERM + ppid）。SSH+launchd 合併錯誤訊息。**`--cli` 模式**（#14）：無需 MCP server 直接呼叫全部 28 個工具。支援 flag-based（`--key value`）和 JSON stdin 兩種模式。智慧型別推論（bool/int/double/array）。MCP Swift SDK 0.12.0（Swift 6.3 相容）。 |
| v1.5.0 | **個別事件時區**（#12）：`create_event`/`update_event`/`create_events_batch` 支援 `timezone` 參數，事件輸出使用事件自身時區，無 offset 時間以事件時區解析。**清除到期日**（#9）：`update_reminder` 新增 `clear_due_date`。**星期驗證**（#5）：`create_event`/`update_event` 驗證 `start_time` 星期是否匹配 `days_of_week`。**復原/重做**（#8）：3 個新工具（`undo`、`redo`、`undo_history`）。**週期事件修正**（#7）：支援 `occurrence_date` 的 occurrence 級別刪除/更新。**Swift 6 建置**（#11）：README 改為 `make release` 流程 |
| v1.4.0 | **LLM 可靠性**：修正預設搜尋範圍（±2 年取代 distantPast/Future）、`search_events` 回傳 `searched_range` metadata、`create_events_batch` 回傳 `similar_events` 提示、tool description 加入 LLM 使用指引 |
| v1.3.1 | **文檔修正**：明確說明標籤為 MCP 層級（非 Reminders.app 原生標籤）；Apple 未提供原生標籤的公開 API |
| v1.3.0 | **提醒事項標籤**（MCP 層級）：`create_reminder`/`update_reminder`/`create_reminders_batch` 支援 `#hashtag` 標籤文字存於備註，`search_reminders` 可依標籤過濾，新增 `list_reminder_tags` 工具；MCP SDK 0.11.0。注意：標籤可透過 MCP 搜尋，但不會成為 Reminders.app 原生標籤（Apple 未提供公開 API） |
| v1.2.0 | **冪等寫入**：`create_event`、`create_events_batch`、`create_reminder`、`create_reminders_batch`、`create_calendar` 寫入前自動查重，防止 Agent 重試產生重複資料；回傳包含 `skipped` 計數 |
| v1.1.0 | **循環規則 + 位置**：循環事件/提醒（每日/每週/每月/每年）、含座標結構化位置、基於地理圍欄的位置提醒觸發、豐富的循環規則輸出 |
| v1.0.0 | **開發體驗改進**：彈性日期解析（4 種格式）、模糊日曆匹配、`list_events`/`list_reminders` 篩選/排序/限制、`delete_events_batch` 預覽模式 + 日期範圍模式 |
| v0.9.0 | **4 個新工具**（20→24）：`update_calendar`、`search_reminders`、`create_reminders_batch`、`delete_reminders_batch` |
| v0.8.2 | **國際化週支援**：`list_events_quick` 新增 `week_starts_on` 參數（monday/sunday/saturday/system） |
| v0.8.1 | **修復**：`update_event` 時間驗證 Bug，移動事件時自動保留持續時間 |
| v0.8.0 | **重大變更**：`calendar_name` 現在是建立操作的必填欄位（移除隱式默認） |
| v0.7.0 | **工具標註**：支援 Anthropic Connectors Directory、自動刷新機制、改進批次工具說明 |
| v0.6.0 | **來源消歧義**：`calendar_source` 參數支援同名日曆區分 |
| v0.5.0 | 批次刪除、重複偵測、多關鍵字搜尋、改善權限錯誤、新增 PRIVACY.md |
| v0.4.0 | 事件複製/移動：`copy_event`、`move_events_batch` |
| v0.3.0 | 進階功能：搜尋、快速範圍、批次建立、衝突檢查、時區顯示 |
| v0.2.0 | Swift 重寫，完整支援提醒事項 |
| v0.1.x | Python 版本（已棄用） |

---

## 貢獻

歡迎貢獻！請隨時提交 Pull Request。

### 發布流程（給維護者）

版本號散落在三個地方，各有不同的角色：

| 檔案 | 角色 | 何時更新 |
|------|------|----------|
| `Sources/CheICalMCP/Version.swift` — `AppVersion.current` | 真正的來源；會出現在 `--version`、`help`、和 MCP `serverInfo.version` | 每次發布 |
| `Sources/CheICalMCP/Info.plist` — `CFBundleVersion` | macOS bundle 版本 | 每次發布；必須跟 `AppVersion.current` 一致 |
| `mcpb/manifest.json` — `version` | Claude Desktop bundle manifest，打包進 `.mcpb` | 每次發布；必須跟 `AppVersion.current` 一致 |
| `server.json` — `version` + `packages[].identifier` + `fileSha256` | **MCP Registry 提交快照** | 只有重新提交新 `.mcpb` 給 MCP Registry 時才更新（獨立節奏） |

`scripts/build-mcpb.sh` 會強制檢查前三個是否一致；任一不同步就會中止 build。`server.json` 故意脫鉤，因為更新它需要重新 build `.mcpb`、產生新的 SHA256、並重新提交 — 這些步驟不會每次原始碼發布都做。

#### 簽章與公證（macOS 26+ 必需）

從 v1.7.1 開始，發布版 binary 會用開發者 ID 應用程式（Developer ID Application）憑證簽章，並透過 Apple 的 `notarytool` 公證。在 macOS 26 上**必須**這樣做 — 因為 ad-hoc 簽章的 binary 無法觸發行事曆/提醒事項的 TCC 權限對話框。

**前置條件**（一次性設定）：

1. 加入 Apple Developer Program。
2. 在登入鑰匙圈裡安裝開發者 ID 應用程式憑證。
   - 用以下指令確認：`security find-identity -p codesigning -v`（必須要看到 `Developer ID Application: <你的名字> (<TeamID>)`）。
   - 你自己的 Team ID 在 <https://developer.apple.com/account> → Membership Details 找。（這個 repo 任何地方出現的 `6W377FS7BS` 是維護者本人的，僅供參考。）
3. 設定 `notarytool` 的鑰匙圈設定檔（名字隨意；`che-ical-mcp` 是 build script 預設會找的名字）。
   - 互動式建立（建議 — 密碼不會留在 shell 歷史）：
     ```bash
     xcrun notarytool store-credentials che-ical-mcp --apple-id <你的-apple-id> --team-id <你的-team-id>
     # notarytool 會詢問 app-specific password
     ```
   - App-specific password：在 <https://account.apple.com> → Sign-In and Security → App-Specific Passwords 產生。用單一用途的密碼（例如取名 `che-ical-mcp`）；外洩立即撤銷重產。**絕對不要**在命令列用 `--password` 傳遞 — 那會留在 `~/.zsh_history`。
4. 匯出 build script 需要的環境變數：
   ```bash
   export DEVELOPER_ID='Developer ID Application: <你的名字> (<TeamID>)'
   export NOTARY_PROFILE='che-ical-mcp'   # 對應步驟 3 設定的名字
   ```
   寫進 `~/.zshrc` 或專案內的 `.envrc`（要 gitignore）。Script **故意不設預設值**，這樣 fork 的人才不會看到指向維護者身份的錯誤訊息。

**每次發布的流程**：

```bash
make release-signed     # 建 universal binary → 簽章 + 公證 → 打包 .mcpb
gh release create vX.Y.Z mcpb/server/CheICalMCP mcpb/server/CheICalMCP.sha256 mcpb/che-ical-mcp-X.Y.Z.mcpb mcpb/che-ical-mcp-X.Y.Z.mcpb.sha256 --notes "..."
```

`make release-signed` 會跑 `scripts/build-mcpb.sh`，建完 universal binary 之後呼叫 `scripts/sign-and-notarize.sh`。簽章 script 會做 pre-flight 檢查（憑證 + notarytool 設定檔），缺東西會 fail-fast 並給出友善訊息。公證通常需要 1–15 分鐘（`notarytool submit --wait` 會 block 直到 Apple 完成）。

**Build 後驗證**（三個都跑來確認 end-to-end 沒問題）：

```bash
# 1. 簽章屬性（憑證 + 強化執行階段（hardened runtime）+ Team ID）
codesign -dv --verbose=2 mcpb/server/CheICalMCP
# 預期：
#   Authority=Developer ID Application: <你的名字> (<TeamID>)
#   TeamIdentifier=<TeamID>
#   flags=0x10000(runtime)
#   Signature size 數千 bytes 範圍（隨憑證鏈而異）

# 2. 簽章完整性
codesign --verify --deep --strict --verbose=2 mcpb/server/CheICalMCP
# 預期：exit 0，沒有警告

# 3. 公證 end-to-end（這才是真正的「Gatekeeper 會接受」門檻）
spctl -a -vvv -t install mcpb/server/CheICalMCP
# 預期：<binary>: accepted; source=Notarized Developer ID
#
# 關於 flag 選擇（在 macOS 26.4.1 經實測確認，2026-05-04）：
#   -t execute → rejected "code is valid but does not seem to be an app"
#                （Apple 的 "execute" 類型期待 .app bundle 結構，不是裸的 Mach-O CLI）
#   -t install → accepted; source=Notarized Developer ID  ← 用這個
#   -t open    → rejected "Insufficient Context"
#
# Apple 的 Code Signing Guide 把 -t execute 描述為「應用程式與工具」（applications and tools）的 assessment 類型，
# 但在 macOS 26 上裸的 Mach-O binary 通不過 .app bundle 檢查。-t install 是「正在安裝
# 的軟體」的 assessment 類型（CLI binary 進到 ~/bin 也算 install），實測上會回傳真正的
# 公證裁決。如果 Apple 在未來 macOS 改變這個行為，要重新驗證。
```

**本機開發迭代**（不想等簽章延遲）：

```bash
SKIP_CODESIGN=1 ./scripts/build-mcpb.sh   # ad-hoc 簽章；不要拿來發布
make install                              # ad-hoc 安裝到 ~/bin（僅供開發）
```

`build-mcpb.sh` 在以下情況會**自動跳過簽章**：`DEVELOPER_ID` 沒設、或憑證不在你的鑰匙圈裡 — 所以貢獻者／CI／fork 的人不需要手動設 `SKIP_CODESIGN` 也可以建出可以測試的未簽 `.mcpb`。（這時候會看到清楚的「Skipping codesign」警告。）

**簽章身份相關環境變數**：

| 環境變數 | 預設值 | 何時需要 |
|---------|--------|----------|
| `DEVELOPER_ID` | _（未設 — 自動跳過簽章）_ | 簽章發布版 |
| `NOTARY_PROFILE` | _（未設 — `sign-and-notarize.sh` 會 fail-fast）_ | 簽章發布版 |
| `ENTITLEMENTS` | `Sources/CheICalMCP/Entitlements.plist` | 自訂 entitlements 檔案 |
| `SKIP_CODESIGN` | _（未設）_ | 即使有憑證也強制跳過簽章（設為 `1` 或 `true`）|
| `REQUIRE_CODESIGN` | _（未設）_ | 缺簽章前置條件就 fail-fast（`make release-signed` 會自動設為 `1` — 正規的發布路徑**不可**悄悄產出未簽的 artifact；直接跑 `./scripts/build-mcpb.sh` 做 fork-friendly 開發 build 時不要設這個）|

**已知限制 — 沒有 stapling**：`stapler staple` 不支援裸的 Mach-O binary（只能處理 `.app` / `.pkg` / `.dmg` bundle）。公證之後，Gatekeeper 會在第一次啟動時上線檢查 binary，而不是讀取 stapled ticket。網路斷線（air-gapped）的使用者第一次可能會看到「無法驗證開發者」的警告；只要連線跑一次就會解決（Apple 會 cache 結果）。Mitigation：未來若包成 `.pkg` 包裝，可以對 `.pkg` 做 `xcrun stapler staple`。

**疑難排解**：

- 公證被拒？`xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE` 會顯示 Apple 的拒絕原因。簽章 script 每次跑都會印出 submission ID。
- `codesign` 抱怨找不到 identity？`security find-identity -p codesigning -v` 確認憑證存在且有效；`xcrun notarytool history --keychain-profile $NOTARY_PROFILE` 確認設定檔可用。
- 憑證過期？在 <https://developer.apple.com/account/resources/certificates> 重新發行、安裝、重新 export `DEVELOPER_ID`。
- 安全提醒：不要在共用/不可信的機器上解鎖簽章鑰匙圈。憑證 + 私鑰是供應鏈安全的關鍵資產。

---

## 授權

MIT License - 詳見 [LICENSE](LICENSE)。

---

## 作者

由 **鄭澈** ([@kiki830621](https://github.com/kiki830621)) 建立

如果覺得有用，請給個 Star 支持一下！

**週期讀取欄位（#198，未發布）：** 事件使用 `event_recurrence_rules`，提醒事項使用 `reminder_recurrence_rules`；兩者都是規則陣列，但缺值與結束日期格式不同。舊 `recurrence_rules` 保留為相容別名。拒絕未知欄位的用戶端需更新解碼器。詳見[格式對照](docs/REMINDER_RECURRENCE.md#recurrence-read-formats-198)。
