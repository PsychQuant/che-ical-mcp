# MCP 功能驗證：先確認測試表面的 binary 版本，再選路徑

Binary 更新（release／plugin-update）後，**session 內的 MCP server 仍是舊版** — 它是
session 啟動時 spawn 的長駐 process，重啟 Claude Code（或 Claude Desktop `Cmd+Q`）
之前不會換 binary。驗證新功能時選錯表面，會拿舊 binary 的行為當新功能的證據（或反過來）。

**而且「重啟＝換新版」也不保證成立**（wrapper failure-cache 坑，見下節）— 所以
行為探測不能因為「我剛重啟過」而省略。

## 鐵律：動手前先做行為探測，不憑假設判定版本

對測試表面呼叫**新版才有的欄位或 tool**，從回應判定版本。例：v1.16.0 的
`create_event` 回應會 echo `excluded_occurrence_dates` + `exclusion_count`；v1.15.0
的舊 parser 靜默忽略該欄位、回應無此欄。一次呼叫即分辨，成本近零。

**兩個方向都踩過**（2026-08-31，#186 undo 補驗）：
- 假設「session MCP = 舊版不可用」而不探測 → 繞路手寫 JSON-RPC harness（浪費，且引入新 confound）
- 反方向同樣危險：假設 session MCP 已是新版 → 舊 binary 靜默忽略新欄位，測試「通過」但什麼都沒驗到

## 三個測試表面的特性（封閉列舉 — 只有這三個，不得類推第四種）

| 表面 | Binary 版本 | 長駐狀態（undo stack 等） | read-after-write |
|------|------------|--------------------------|------------------|
| **Session MCP tools**（`mcp__che-ical-mcp__*`） | session 啟動時的 `~/bin/CheICalMCP`（更新後 = **舊版**，重啟才換） | ✅ 有 | ✅ 正常 |
| **`--cli` 單發**（`<binary> --cli` 或 stdin JSON） | 指定路徑的 binary — 可直接指 `mcpb/server/CheICalMCP`（**剛 build 的最新版**） | ❌ 無 — 每次呼叫是獨立 process，in-memory 狀態（undo/redo stack）隨 process 消失，`undo` 永遠回 "Nothing to undo" | ✅ 跨 process 讀正常 |
| **手動 spawn stdio server**（JSON-RPC pipe 長駐 process） | 指定路徑的 binary | ✅ 有 | ❌ **不可靠** — 同 process 內緊接查詢讀不到剛寫入的事件（加 1.5s pacing 亦然，2026-08-31 實測）；list 斷言面失效，只有 tool 回應訊息可作證據 |

## 路徑選擇（依待驗功能的性質）

1. **Stateless 功能**（欄位驗證、事件建立/查詢/排除語意）→ `--cli` 指向 repo 內剛 build
   的 binary。每次 fresh process、跨 process 讀正常，是 release 前實機驗證的首選。
2. **Stateful 功能**（undo/redo、任何 in-memory 跨呼叫狀態）→ 唯一乾淨表面是
   **重啟後的 session MCP tools**。`--cli` 結構上驗不了（per-process stack）；手動
   spawn 只能拿到 tool 回應訊息級的證據（"Undone batch (3 operations)" 可證機制在動，
   但「事件真的回來了」的 list 斷言會被 read-after-write confound 汙染）。
3. Release／plugin-update 完成的報告**必須明示**：「本 session 的 MCP server 仍為
   舊版 vX，重啟後生效」— 別讓下一個動作在錯的表面上驗證。

## Wrapper failure-cache 坑：重啟後 binary 仍可能是舊版（2026-08-31 實踩）

Plugin 的 wrapper（`plugins cache .../bin/*-wrapper.sh`）負責 auto-download：spawn 時比對
plugin.json 版本 vs `~/bin/.<Binary>.version` sidecar，不一致就下載 + atomic swap。
**它的前提是 wrapper 被 spawn** — 而有一條安靜的失效鏈會讓這個前提落空：

1. Release 後第一次重啟：wrapper 開始下載新 binary（19MB 級）→ 超過 Claude Code 的
   30 秒 MCP connect timeout → `plugin:<name>` 連線標記失敗；
2. Claude Code 把該失敗 **cache 15 分鐘**（「Skipping connection (recent failure cached)」）；
3. 15 分鐘內再重啟：plugin server 連線**直接跳過、wrapper 不被 spawn** → auto-download
   不觸發 → `~/bin` 停在舊版；
4. 整條鏈**無錯誤訊息** — 唯一可見訊號是 session-start hook 的「vX → vY available」提示，
   以及行為探測的結果。

**處置**（不是手動 curl — 用 plugin 自己的機制）：直接執行 plugin cache 裡最新版目錄的
wrapper 一次，stdin 給 EOF 讓 server 下載完即退出，再驗版本與 sidecar：

```bash
WRAPPER=~/.claude/plugins/cache/<mp>/<plugin>/<newest-ver>/bin/*-wrapper.sh
timeout 90 $WRAPPER </dev/null 2>&1 | head -5   # 看到 "installed vX.Y.Z" 即成功
~/bin/<Binary> --version && cat ~/bin/.<Binary>.version
```

注意：換完檔案後，**已在跑的 server process 仍是舊 binary**（atomic mv 不影響 running
process 的 inode）— 本 session 的探測結果不會因此改變，下次 spawn 才是新版。drift banner
的「N stale processes」多半就是這些活 session 的舊 server，各 client 重啟自然汰換，
不需要 pkill。

## 事故記錄（為什麼是規則不是備忘）

2026-08-31 #186 undo 補驗：v1.16.0 出貨後要驗 #182/#185 的 undo 新行為。先假設
session MCP 不可用（未探測）→ 手寫 stdio harness → 三個 FAIL 全是 harness confound
（read-after-write）而非產品 bug，浪費兩輪偵錯；使用者指正後改用 session MCP 行為
探測，一次呼叫即確認 server 為 v1.15.0。手動 harness 唯一的淨收穫是 tool 回應級
證據（#185 batch undo 機制證實）與一個真訊號（series restore `ekcaderrordomain
1010`）— 但兩者本可在重啟後 30 秒內以乾淨表面取得。

2026-08-31 v1.16.1 wrapper failure-cache：release + plugin sync 完成後重啟，預期
「wrapper 會 auto-download、session server 是新版」— 行為探測卻顯示 server 仍是
v1.16.0。追查發現 plugin server 連線被 15 分鐘 failure cache 跳過、wrapper 從未被
spawn（上節整條鏈）。手動執行 plugin cache 的 wrapper 一次即完成下載。若當時未探測
而直接在 session MCP 表面驗 v1.16.1 的新行為，會拿舊 binary 的結果當新版證據 —
正是本規則鐵律要防的方向之二。

## Release gate：undo post-state guard（#236）

#236 的 guard（item 在操作之後被改過時，undo / redo 拒絕寫入）只有純邏輯部分有單元測試：
欄位比對、resolve → refresh → compare 的順序（`UndoTargetCheck`）、拒絕方式的選擇、batch
順序。`executeUndo` / `executeRedo` 裡圍繞它們的 EventKit 呼叫沒有任何自動測試，而 undo 是
stateful，`--cli` 走不到（見上表）。**出 #236 的那個版本打 tag 之前**，在重啟後的 session
MCP 上（行為探測確認是新 binary 之後），只用名稱含 `#236` 的拋棄式日曆與清單，至少驗：

1. `create_event` → undo 刪掉它；`create_event` → 在 Calendar.app 改標題 → undo 拒絕並列出
   `title`、`undo_history` 仍有該筆、`discard_id` 可移除。
2. 每週系列 → 在 Calendar.app 單獨改其中一個場次 → undo 以 `modified_occurrences` 拒絕，什麼都沒刪。
3. 一次性（不重複）事件的 `update_event` → 手動把欄位改回原值 → undo 成功。
4. `complete_reminder` → undo 還原；redo 再完成一次。
5. 帶欄位建立 → 等至少 60 秒 → 不做任何修改 → undo 要成功刪掉：(a) 有鬧鐘、`location` 字串、
   非本機 `timezone` 的事件；(b) 全天事件（EventKit 存檔前就會自動加一個預設鬧鐘，紀錄裡已有它）；
   (c) 有 `due_date` 與 `location_trigger` 的提醒事項。任何一個以 `calendar` / `timezone` /
   `alarms` / `structured_location` / `list` 拒絕，就是有欄位在同步後自己變了，要加豁免。
6. 用 `recurrence.excluded_occurrence_dates` 建立的系列 → undo 一次刪掉整個系列，不出現
   `modified_occurrences`。#182 的「排除日是被移除的場次、不是被單獨修改的場次」只在 iCloud
   看過（2026-10-05）；有其他來源（Google、Exchange）的帳號時，在那裡再做一次。
7. 建立每週系列 → `update_event` 帶 `occurrence_date` 改其中一個場次 → undo：拒絕、什麼都沒寫、
   訊息說要改回請到行事曆，紀錄被丟棄（`undo_history` 原本列為 `Updated recurring event: …
   (undo not available)`）→ 再 undo（create-undo）：以 `modified_occurrences` 拒絕，系列完整。
   `span: "future"`、`span: "all"`、為一次性事件加上重複規則、移除重複規則也各做一次：update
   的 undo 一律拒絕並丟棄、什麼都沒寫。**`span: "all"` 的 update-undo 只在拋棄式日曆上測**；
   #262 修正之前的 binary 會刪掉真實系列的其餘場次。另外在別的 app（或另一個 process）只改一個
   場次的時間、只改一個場次的鬧鐘 → create-undo 以 `modified_occurrences` 拒絕。
8. 循環提醒事項完成後滾到下一個場次 → undo：紀錄被丟棄（#204 的訊息，或沒有場次快照的紀錄的
   successor-shape 訊息），什麼都沒寫到下一個場次，較舊的紀錄可以 undo。

結果記在 #236。結束後刪掉拋棄式日曆與清單。
