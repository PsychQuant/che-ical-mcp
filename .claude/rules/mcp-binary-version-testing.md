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
7. 循環事件的 update-undo 一律拒絕、什麼都不寫、紀錄被丟棄（訊息說要改回請到行事曆）。逐項各做一次，
   每項都用新建的拋棄式系列：
   (a) 帶 `occurrence_date` 改一個場次 → undo 拒絕（`undo_history` 原本列為 `Updated recurring
       event: … (undo not available)`）→ 再 undo（create-undo）以 `modified_occurrences` 拒絕，系列完整；
   (b) `span: "future"` → undo 拒絕 → create-undo 以 `recurrence` 拒絕，訊息說系列被縮短、只給放棄
       （`discard_id`），不叫人改回；
   (c) `span: "all"` → undo 拒絕，系列每個場次都還在（**只在拋棄式日曆上測**；#262 修正之前的
       binary 會刪掉真實系列的其餘場次）；
   (d) 一次性事件加上重複規則 → undo 拒絕；(e) 系列 `clear_recurrence` → undo 拒絕；
   (f) 用場次自己的 id（`<series>/RID=…`）改一個已 detached 的場次 → undo 拒絕；
   (g) 一次性事件改標題 → 再加上重複規則 → undo（拒絕並丟棄）→ undo：以「it repeats now」拒絕並丟棄，
       什麼都沒寫；(h) 一次性事件改標題 → 在別的 app 讓它變成重複事件 → undo：同 (g)。
   另外在別的 app（或另一個 process）只改一個場次的時間、只改一個場次的鬧鐘 → create-undo 以
   `modified_occurrences` 拒絕。(i) 一次性事件 `move_events_batch` 到另一個拋棄式日曆 → undo 搬回
   （對照組）；再做一次，搬移後在別的 app 讓它變成重複事件 → undo：「Cannot undo the move …
   it repeats now」，丟棄、什麼都沒寫。
8. 循環提醒事項完成後滾到下一個場次 → undo：紀錄被丟棄（#204 的訊息，或沒有場次快照的紀錄的
   successor-shape 訊息），什麼都沒寫到下一個場次，較舊的紀錄可以 undo。
9. **非 iCloud 來源的對照組**（有 Google 或 Exchange 帳號時）：在該來源的拋棄式日曆建一次性事件 →
   `update_event` 改標題 → undo 要成功還原；另建一個一次性事件 → `move_events_batch` 到同來源的另一個
   拋棄式日曆 → undo 要成功搬回。若以「it is an edited occurrence of a series now」拒絕，
   就是該來源把一次性事件回報成 detached（`isDetached` 誤判），要回報、別在真實資料上依賴這兩條 undo。
   另建一個一次性事件 → `update_event` 帶 `recurrence`、不帶 span，要成功（#434）：單一場次的拒絕也看
   `isDetached`，誤判的來源會把一次性事件當成單一場次拒絕，訊息說它是 edited on its own。
   另在該來源的兩個拋棄式日曆做第 10 步（經 stand-in 的整串搬移之 undo，#369）：它靠搬移後舊的系列物件
   回報新日曆，這只在 iCloud 看過（2026-11-04）。若 undo 以「still resolves, but neither the series nor an
   occurrence that could stand in for it can be read」拒絕，就是該來源的舊物件回報的還是原日曆，要回報。
   也在該來源的拋棄式日曆做第 11 步（#377）：它靠舊的系列物件 refresh 失敗、仍掃得到最早剩下的場次，且該場次
   的開始時間晚於 create 紀錄的開始時間（`created.startDate`），這只在 iCloud 看過（2026-11-04）。若 undo 以
   「although an occurrence of it can still be read」的中性訊息拒絕，就是該來源最早剩下的（未單獨修改的）場次
   沒有晚於紀錄的開始時間，要回報。已知限制（低可能性，不修）：第一個場次還在但被單獨改過、而系列物件又因別的
   原因 refresh 失敗時，掃描會跳過它（detached），訊息會把它說成「第一個場次被刪」。
10. **經 stand-in 的整串搬移之 undo（#369）**：系列的建立與刪第一個場次要用 `--cli`（各自獨立的 process）做，
    不要在 session MCP 上做，讓這兩個寫入不進 session 的 undo stack，最上面兩筆才會是 (b) 列的那兩筆。拋棄式日曆 A、B（同一 iCloud 帳號）：
    (a) `--cli`：在 A 建每週 5 次的系列 → `--cli`：`delete_event` span `this` 刪第一個場次；
    (b) session MCP：在 A 建一筆一次性事件 → `move_events_batch` 用系列的 bare id、span `all` 搬到 B
        （`in_place`、id 不變、B 有 4 個場次）。此時 `undo_history` 最上面兩筆由上而下是
        「Moved event」、「Created event: <一次性事件>」；同一個 session 先做過第 1–9 步時，
        它們下面還有那些步驟留下的紀錄，這是預期的；
    (c) `undo`：4 個場次回到 A、id 不變 → `undo`：刪掉那筆一次性事件（堆疊沒被卡住）。
    (d) 已經在 Calendar.app 搬回去的情況：重做 (a)(b)，undo 之前先在 Calendar.app 把整個系列搬回 A →
        `undo` 要被接受，而且什麼都沒改：所有場次仍在 A、id 不變。這一項依賴兩件沒驗過的事：Calendar.app 搬回後
        bare id 仍解析得到，以及舊的系列物件改回報 A。若 undo 以上面第 9 步引的 residual not-found 拒絕（什麼都沒寫、
        紀錄保留），記錄下來回報到 #369，當成已知限制，不是安全問題；以其他方式寫入才是 bug。
    再做一次 edited-before 形狀：(a) 之後用 `--cli` 的 `update_event` span `this` 單獨改第一個剩下的場次，
    再做 (b)(c)，4 個場次（含被改過的）都回到 A。
    **系列的 create-undo 會被拒絕**：在 session MCP 上建系列、刪第一個場次之後，undo 過了 delete-undo，
    create-undo 會以「Cannot undo the creation of the recurring event … first occurrence is deleted」拒絕、什麼都
    沒寫、紀錄保留（#377，見第 11 步），會卡住下面的紀錄，所以 (a) 才要放在 `--cli` 做。2026-11-04 已用 repo 內 build 的 binary 以單一 stdio process 做過 (b)(c) 與 edited-before 形狀，
    跨 process 的 `list_events` 確認結果；出版前在重啟後的 session MCP 上重做一次。跨帳號搬回（拒絕、紀錄保留）
    沒有在裝置上驗過：只在有第二個帳號的拋棄式日曆時做。
11. **第一個場次被刪掉之後，系列的 create-undo（#377）**：拋棄式日曆（名稱含 `#377`）。session MCP：建每週 5 次的
    系列 → `delete_event` span `this` 刪第一個場次 → `undo`（delete-undo：把那個場次還原成一次性事件）→ `undo`：
    要以「Cannot undo the creation of the recurring event '…': the series this undo would delete no longer reads,
    while a later occurrence of it remains …」拒絕，什麼都沒寫（`list_events` 仍是 4 個系列場次加 1 個一次性事件），
    `undo_history` 最上面仍是「Created event」。訊息的最後一句要是「…call undo with discard_id set to its id; the series
    can then be deleted by hand if it should still go.」，不點名任何刪除工具（刪不刪是使用者的事）。照訊息的順序走：
    先 `undo` 帶該筆的 `discard_id` 移除它；之後測試者**自己**用 `delete_event` span `all`、系列的 bare id 刪掉剩下的
    場次（成功，`undo_history` 最上面變成這筆 delete）。順序反過來會失敗：delete 的紀錄會蓋在 create 上面，
    `discard_id` 只能移除最上面那筆。
    若回的是原本的「not found under its recorded identifier」，就是系列的 bare id 在該來源上已經解析不到（不是 #326
    的形狀），探測位置要移；若回的是「although an occurrence of it can still be read」的中性訊息，就是 stand-in 的開始
    時間沒有晚於紀錄裡的開始時間（`created.startDate`）；兩種都回報到 #377。
    **edited-before 形狀**：另建一個系列，用 `--cli` 刪第一個場次、再用 `--cli` 的 `update_event` span `this` 改第二個
    場次的標題（兩個寫入都不進 session 的 undo stack）→ session `undo`：同樣的拒絕（stand-in 是第三個場次）→
    `discard_id` 移除 → `delete_event` span `all` 會以 edited-before 拒絕（訊息說可以怎麼逐一刪），這是預期的。
    **edited-after 形狀**：另建一個系列，用 `--cli` 刪第一個場次、再用 `--cli` 改第三個場次（在 stand-in 之後）的標題 →
    session `undo`：同樣的拒絕 → `discard_id` 移除 → 測試者自己 `delete_event` span `all`：**連被單獨改過的第三個場次也
    一起刪掉**。這是 `delete_event` 的預期行為（它不做 create-undo 的 `modified_occurrences` 檢查），不是 undo 的；也正是
    訊息不點名刪除工具、把刪除留給使用者手動做的原因。
    2026-11-04 已用 repo 內 build 的 binary 以單一 stdio process 在 iCloud 做過這三個形狀（含 discard 再 delete 的順序，
    跨 process 的 `list_events` 確認；edited-after 形狀刪除前有 4 個場次、含改過的那個，刪除後 0 個）；出版前在重啟後
    的 session MCP 上重做一次。
12. **還原目標日曆不見了（#269）**：拋棄式日曆（名稱含 `#269`）。session MCP：
    (a) 在日曆 A 建一次性事件 → `delete_event` → 刪掉日曆 A → `undo`：要以「Cannot undo the deletion of an event
        (event '…'): the calendar it was in when it was deleted is not available (deleted, or its account turned off or
        still syncing); it was not found under its recorded identifier.」拒絕，訊息裡**沒有日曆名稱也沒有帳號**（#37、
        #290），什麼都沒寫、`undo_history` 最上面仍是「Deleted event」，最後一句是「To go on, ask the user whether to give
        up this undo; if they agree, read undo_history and call undo with discard_id set to its id.」，不點名任何其他工具
        → `undo` 帶該筆的 `discard_id` 移除它；
    (b) 日曆 C、D：在 C 建一次性事件 → `move_events_batch` 搬到 D → 刪掉日曆 C → `undo`：「Cannot undo the move of an
        event (event '…'): the calendar it was moved from is not available …」，事件仍在 D → `discard_id` 移除；
    (c) 經 stand-in 的整串搬移（第 10 步的 (a)(b)）之後刪掉 A → `undo`：同 (b) 的訊息，系列仍在 B。PR #389 第二輪起
        move 臂先讀日曆、再做 #236 的檢查，所以這個訊息由 move 臂的 `restoreCalendar` 丟出；`SeriesMoveUndo.decide` 那一處
        只在兩次讀取之間日曆剛好被刪時才會走到。
    (d) 對照組（日曆還在）：在拋棄式日曆建一次性事件 → `delete_event` → `undo`：要成功還原（這次讀日曆會先做 Calendar
        access 檢查，日曆在就不會被判成不見）。
    (e) update-undo 那一臂：日曆 C、D：在 C 建一次性事件 → `update_event` 帶 `calendar_name` 把它從 C 改到 D → 刪掉日曆 C
        → `undo`：「Cannot undo the update of an event (event '…'): the calendar it was in before the update is not
        available …」，事件不變（仍在 D、欄位是更新後的值），`undo_history` 最上面仍是「Updated event」→ `discard_id` 移除。
    (f) occurrence-delete 那一臂：在日曆 A 建每週 3 次的系列 → `delete_event` span `this` 刪第二個場次 → 刪掉日曆 A →
        `undo`：「Cannot undo the deletion of an occurrence of an event (event '…'): the calendar it was in when it was
        deleted is not available …」，什麼都沒寫，紀錄保留 → `discard_id` 移除。
    若回的仍是「Calendar not found: <identifier>」，就是測試表面還是舊 binary。2026-11-04 已在 iCloud 用 repo 內
    build 的 binary 做過 (a)(b)(c)（PR #389 第一輪 verify 前的版本，當時的訊息還帶日曆名與帳號）；第一輪修正後的
    binary 重做了 (a)(b)(d)，訊息只寫事件名、沒有日曆名與帳號，(d) 成功還原（結果見 #269 的 Verify-fix）；(c) 沒有
    用修正後的 binary 重做。**出版前仍欠**：用修正後的 binary 做 (c)，以及第一次做 (e)(f)。最初那次的細節：(a)(b) 各在一個 stdio process 裡，(c) 的系列建立與刪第一個場次用 `--cli`、搬移與
    undo 在一個 stdio process 裡；三者都回上面的訊息、`discard_id` 都移除了該筆，跨 process 的 `list_events` 確認事件
    仍在搬去的日曆。(c) 從訊息分不出是 `decide` 還是 move arm 丟的（兩處同一個訊息）。update-undo 的那一臂沒有在裝置上做。
    出版前在重啟後的 session MCP 上重做一次。

結果記在 #236。結束後刪掉拋棄式日曆與清單。

## Release gate：timed → all-day 只帶 start_time 的天數（#374）

#374 的規則（只帶 `start_time` 把 timed 事件改成 all-day 時，保留 timed 範圍碰到的天數）只有
`AllDayRange.planUpdate` 的單元測試；寫入的是 #364 裝置檢查已涵蓋的 normalized all-day pair，
所以這是確認、不是新的前提。**出 #374 的那個版本打 tag 之前**，用剛 build 的 binary 的 `--cli`
（stateless，見上表），只在名稱含 `#374` 的拋棄式日曆上：

1. 建一個 timed 事件 `22:00` 到隔天 `02:00`；
2. `update_event` 帶 `all_day: true, start_time: <某個日期>`（不帶 `end_time`）；
3. `list_events` 讀回：是兩天的 all-day 事件（第一天 `00:00` 到第二天 `23:59:59`）。

結果記在 #374。結束後刪掉拋棄式日曆。

## Release gate：find_duplicate_events（#437）

兩項 PR #440 在開發時沒有量：`create_calendar` 只能建在預設來源，所以兩個帳號同名要手動建；沒給
`calendar_names` 的讀取會碰真實行事曆，所以由使用者本人做，只比數字，不讀事件內容。**出 #437 的那個版本
打 tag 之前**：

1. **兩個帳號同名**（有第二個來源時）：在 Calendar.app 於第二個來源手動建拋棄式日曆，再用 `create_calendar`
   建同名日曆（名稱含 `#437`，預設來源）。兩邊各用 `create_event` 建同標題同時間的事件 →
   `find_duplicate_events` 的 `calendar_names` 只給那個名稱：`duplicate_count` 是 1，`calendars_checked`
   列出 `<名稱> (<來源>)` 兩筆，配對兩邊的 `calendar_source` 不同。
2. **沒給名稱**（使用者本人做，代理不要跑）：用舊版與新版 binary 對同一個範圍各呼叫一次、都不給
   `calendar_names`，比較 `duplicate_count`，兩者要相同。再核對 `calendars_checked` 的長度等於
   `list_calendars` 回傳的事件行事曆數。
   - 舊版回應的 `calendars_checked` 是 `all calendars`，這裡只比 `duplicate_count`。
   - 不同代表 `calendars: nil` 改成明列全部行事曆之後讀到的範圍變了，要回報。

結果記在 #437。結束後刪掉拋棄式日曆（第二個來源的那個也要手動刪）。做完後把 README 與 CHANGELOG 的
「沒有在裝置上跑過」改成量到的結果。

## Release gate：update_event 存檔失敗後的 rollback（#373）

#373 verify 讓 `updateEvent` 在 `eventStore.save` 丟錯時先 `event.rollback()` 再回傳錯誤；這只有
原始碼結構測試（`UpdateEventRefusalOrderTests.testAFailedSaveRollsTheEventBack`），EventKit 在存檔失敗後
實際留下什麼沒有在裝置上看過（#261 的問題）。這是 stateful 的（同一個 server process 內的下一次
寫入），所以**出 #373 這個修正的版本打 tag 之前**，在重啟後的 session MCP 上（行為探測確認是新 binary
之後），只用名稱含 `#373` 的拋棄式日曆：

1. 在拋棄式日曆建一個一次性事件；
2. 對它做一次 EventKit 會拒絕的 `update_event`（例如帶新標題，加上 `calendar_name` 指向一個唯讀日曆，
   像訂閱的節日日曆），確認回傳錯誤；
3. 在同一個 session 對同一個事件做一次只改 `notes` 的 `update_event`；
4. `list_events` 讀回：標題仍是原本的標題、仍在拋棄式日曆，只有 notes 改了。

結果記在 #373 與 #274。結束後刪掉拋棄式日曆。

## Release gate：提醒事項的相對鬧鐘與它的 undo（#333）

#333 的 `alarms_minutes_offsets` 只有純函式與 handler 的單元測試；寫進 EventKit 後的讀回只在 `--cli`
上看過，update-undo 是 stateful，`--cli` 走不到（見上表）。**出 #333 的那個版本打 tag 之前**，在重啟後的
session MCP 上（行為探測確認是新 binary 之後），只用名稱含 `#333` 的拋棄式清單：

1. `create_reminder` 帶時間的到期日、`location_trigger` 與 `alarms_minutes_offsets: [15]` → `list_reminders`
   讀回 `minutes_before: 15` 與 `location_trigger`；
2. `update_reminder` 只帶 `alarms_minutes_offsets: [60]` → 讀回只有 60，`location_trigger` 還在 →
   `undo` → 讀回 15，`location_trigger` 還在；
3. `update_reminder` 帶 `alarms_minutes_offsets: []` → 相對鬧鐘清空，`location_trigger` 還在；
4. 純日期提醒帶 `alarms_minutes_offsets: [240]` → 拒絕、什麼都沒寫。
5. 建立帶時間到期日與 `[15]` 的提醒 → 等至少 60 秒、什麼都不改 → `undo` 要刪掉它（#236 的 post-state guard
   比對 `relativeOffset`；以 `alarms` 拒絕就是同步後 offset 變了，要回報）。
6. 循環提醒（每週）帶時間到期日與 `[15]` → `complete_reminder` → `list_reminders`（`filter: all`）找下一個場次：
   同標題、`is_completed: false` 的那一筆（完成的那一筆會變成另一個 id），確認它的到期日剛好晚一週、時間相同，
   再看它的 `alarms` 仍是 `minutes_before: 15`（「鬧鐘跟著每一次重複移動」目前只是 EventKit 的預期語意）。

7. `alarms_note` 的數目：建帶時間到期日與 `[15]` 的提醒 → `update_reminder` 帶 `clear_due_date: true`（不帶
   `alarms_minutes_offsets`）→ 回應的 `alarms_note` 說留下 1 個，與 `list_reminders` 讀回的 `alarms` 相符（這條路徑
   存檔後不重讀，數目是記憶體裡的值）。再建一個，用只給日期的 `due_date` 做一次，同樣比對。

**需要使用者在場的兩步**（`--cli` 與 stdio 看不到，不可用 AppleScript 代替）：

8. 這一步用自己的提醒（第 1 步的提醒在第 3 步已清掉相對鬧鐘、第 5 步的會被 undo 刪掉，都不能用）：
   `create_reminder` 帶**至少一天後**的時間到期日與 `[15]`（遠的到期日，它的鬧鐘才不會在第 9 步等待時響起被算錯；
   看完就刪掉它），`list_reminders` 讀回 `minutes_before: 15` → 打開 Reminders.app
   看它：顯示的日期與時間要是**這一步給的到期時間**，不是「到期減 15 分鐘」（#227 / #235 看過 Reminders.app
   會把鬧鐘時間當成提醒的日期顯示）。
9. 建一個到期在幾分鐘後、帶 `[2]` 的提醒，等到它的通知：要在到期前 2 分鐘出現一次。到期當下若又出一次通知，
   **記錄下來、不算失敗**：Reminders 對有到期時間的提醒本來就會在到期時通知，這一步要驗的只是那個提前 2 分鐘
   的相對鬧鐘有沒有響；到期前 2 分鐘沒有通知才算失敗。

結果記在 #333。結束後刪掉拋棄式清單，用 `list_calendars` 確認。

## Release gate：完成重複提醒後 store 加上的 0 分鐘鬧鐘（#423）

#423 的回報只有純函式、記憶體內與 handler 的測試，另外在 `--cli` 上看過。重讀時發現場次已經變了（`alarms_read_back:
false`）這條路只有單元測試，`--cli` 造不出來。**出 #423 的那個版本打 tag 之前**，用剛
build 的 binary 的 `--cli`，只在名稱含 `#423` 的拋棄式清單：

1. 建每週重複、帶位置提醒與 `[15]` 的提醒 → `complete_reminder` → 回應的 `next_occurrence.alarms_minutes_offsets` 是
   `[15, 0]`、有 `alarms_note`；`list_reminders` 讀回下一個場次一致；
2. 同樣但不帶位置提醒 → 回應 `[15]`、沒有 `alarms_note`。
3. 其他形狀，每個都帶位置提醒（2026-11-05 量過，記錄有沒有變）：`end_date`、date-only、daily、monthly、yearly 都是
   `confirmed`、沒有 `alarms_read_back: false`、有 `alarms_note`；每週加 `occurrence_count: 3` 也是 `confirmed`
   （#429），`next_occurrence` 的 rollover 把 count 減一，最後一個場次原地完成，是 `unknown`（`successor_not_observed`）。
   出現 `alarms_read_back: false` 就是重讀比對擋掉了正常 rollover，要回報；`occurrence_count` 的提醒出現
   `recurrence_unverified`，就是 rollover 改了 count 減一以外的東西（只在 iCloud 量過），也要回報。
4. 移除再完成：第 1 步之後用 `update_reminder` 把清單改成 `[15]`（只帶位置時用 `[]`）→ 再 `complete_reminder` →
   回應沒有 `alarms_note`、`list_reminders` 讀回的下一個場次沒有 0 分鐘鬧鐘（2026-11-05 量過三筆，之後一到兩次完成都沒有加回來）。
5. **長駐 process**（`--cli` 每次都是新 store，證明不了這一步）：在重啟後的 session MCP 上，先用行為探測確認是新
   binary，同一個 session 先讀寫幾次，再完成帶位置提醒與 `[15]` 的每週提醒 → 回應是 `[15, 0]`、有 `alarms_note`、
   沒有 `alarms_read_back: false` → 用另一個 `--cli` process 讀回比對。回應是 `[15]` 或 `false` 而 `--cli` 讀到
   `[15, 0]`，就是 reload 沒有讀到 rollover 的結果。2026-11-05 用長駐 stdio server 量過八筆（完成之前分別是剛建立、
   列表、更新、等 3 秒、完成另一筆），都正確；這個 reload 不跑 `refreshSourcesIfNecessary()`。
   再加 count 系列（#429）：同一個 session 建每週、`occurrence_count: 3`、帶位置提醒與 `[15]` 的提醒，連續完成兩次 →
   兩次都是 `confirmed`、`[15, 0]`，第一次有 `alarms_note`、第二次沒有，都沒有 `alarms_read_back: false` → 第三次原地
   完成，`unknown`（`successor_not_observed`）→ 用 `--cli` 讀回，最後一筆的 `occurrence_count` 是 1。2026-11-05 用長駐
   stdio server 量過兩筆（有無位置提醒各一），都正確。

**需要使用者在場的一步**（`--cli` 與 stdio 看不到，不可用 AppleScript 代替）：

6. 建一個每週重複、帶位置提醒、到期在幾分鐘後的提醒，**位置要選離測試者很遠的地方**，否則位置提醒自己也可能
   跳通知，分不出是哪一個鬧鐘 → `complete_reminder`（下一個場次會在一週後；為了看這個鬧鐘，把下一個場次用
   `update_reminder` 的 `due_date` 改到幾分鐘後）→ 用 `list_reminders` 讀回，確認改期之後 0 分鐘鬧鐘還在；不在就
   記錄下來，這一步的通知結果不算數 → 打開 Reminders.app 看下一個場次：記錄是否顯示這個 0 分鐘鬧鐘；等到到期時間，
   記錄是否跳出通知。

結果記在 #423。結束後刪掉拋棄式清單，用 `list_calendars` 確認。

## Release gate：update_reminder 改重複規則與它的 undo（#354）

#354 的規則改寫只有純函式、記憶體內的 `apply` 與 handler 的單元測試；寫入後的讀回在 `--cli` 上看過，undo 是
stateful，`--cli` 走不到。**出 #354 的那個版本打 tag 之前**，在重啟後的 session MCP 上（行為探測確認是新 binary
之後），只用名稱含 `#354` 的拋棄式清單：

1. 建每週四、到期在週四的提醒 → `update_reminder` 帶 `recurrence`（每週五，`days_of_week: [6]`）→ 回應的
   `reminder_recurrence_rules` 是一個規則物件的陣列，`reminder_recurrence_rules[0].days_of_week` 是 `[6]`，`due` 仍是
   週四、有 `recurrence_note`、`id_changed: false` → `undo` → `list_reminders` 讀回每週四；
2. 同樣的提醒 `clear_recurrence: true` → 讀回 `has_recurrence: false`、到期日不變 → `undo` → 讀回每週四；
3. 單次提醒加上規則 → `undo` → 讀回單次；
4. 重複提醒 `clear_due_date: true` → 拒絕、什麼都沒寫；再同時帶 `clear_recurrence: true` → 變成沒有到期日的單次提醒
   → `undo` → 讀回每週四、到期日回來；
5. 改成每週五後等至少 60 秒、什麼都不改 → `undo` 要成功（post-state guard 比對規則；以 `recurrence` 拒絕就是同步
   後規則的讀回變了，要回報）。再做一次子步驟：**純日期**到期日的提醒，`recurrence` 帶 `end_date` → 等至少 60 秒 →
   `undo` 要成功（純日期提醒的規則結束日現在按日比對；若仍以 `recurrence` 拒絕，記下讀回的 `end_date`）。
6. 其他形狀，各做一次並 `complete_reminder`，用 `list_reminders`（`filter: all`）找同標題、未完成的下一筆，記下它的
   到期日（「完成後照規則重複」只量過每週、`interval` 1、只有一個 `days_of_week`、沒有 end 或 count 的規則）：(a) 每週但不帶 `days_of_week`；(b) 每月帶
   `days_of_month`（到期日不在那天）；(c) 單次提醒加上每週規則（到期日不在規則的星期）。

**需要使用者在場的一步**（`--cli` 與 stdio 看不到，不可用 AppleScript 代替）：

7. 打開 Reminders.app 看第 1 步改成每週五、到期仍在週四的提醒（undo 之前）：記錄它顯示的日期與重複設定。

結果記在 #354。結束後刪掉拋棄式清單，用 `list_calendars` 確認。

## Release gate：create_reminder fallback 第二次存檔失敗後的 rollback（#308）

#308 讓 timed `create_reminder`（與 `create_reminders_batch` 的 timed 列）存檔後讀回；讀回時 due
掉了時間或時區，就跑 #237 fallback，把這筆**已經存進 store** 的提醒事項再存一次，失敗時呼叫
`reminder.rollback()`、回報 `aligned: false`。單元測試（`ReminderCreateWriteTests`）只看得到
`rollback` 有被呼叫；`rollback()` 是否真的丟掉一筆已在 store 的提醒事項上待存的改動，**沒有在
裝置上看過**——這正是 #274 對 reminder 尚未回答的問題，兩者用同一個探測就能一起回答。

前提是要有一個「存檔後會丟掉 due 時區」的來源；iCloud 會保住時區（2026-11-05 實測，timed create
讀回 `aligned: true`），所以在 iCloud 上 fallback 根本不會跑，這一步無法在 iCloud 誘發。**出 #308
的那個版本打 tag 之前**：

1. 若手邊有已知會丟時區的來源（#237 的紀錄只確認 iCloud 與 Exchange 會保住），在該來源名稱含
   `#308` 的拋棄式清單上做 timed `create_reminder`，記下 `date_sync`；看 stderr 有沒有
   `create_reminder: the saved due date read back without its time or zone` 這行。
2. 沒有這樣的來源時，這一步不能在裝置上做：在 #274 的 reminder 探測（`update_reminder` 存檔失敗後
   同一個 session 的下一次寫入）做完之前，把 #308 的 fallback rollback 視為未驗證，release note
   照 CHANGELOG 的寫法說明，不寫成已確認。

結果記在 #308 與 #274。結束後刪掉拋棄式清單。

## Release gate：首場被刪除的系列，經 stand-in 的 delete / update 之 undo（#335）

#335 的 items 3、4 只在單一 stdio process 驗過（2026-11-01 與 2026-11-05，iCloud）。**下一個 tag 之前**，
在重啟後的 session MCP 上（行為探測確認是新 binary 之後），只用名稱含 `#335` 的拋棄式日曆，系列的建立與
刪第一個場次都用 `--cli` 做（不進 session 的 undo stack）：

1. 每週 5 次的系列 → `--cli` 刪第一個場次（span `this`）→ session：`delete_event` 用 bare id、span `future`、
   `occurrence_date` 為 stand-in 的日期 → `undo`：新 id、同一行事曆、剩下的 4 個日期都回來，不多一個；
2. 同上，改用 span `all`；
3. 同上的系列 → session：`update_event` span `this` 改一個較晚場次的標題 → `undo`：以「Undo does not restore
   updates that touched a recurring event」拒絕，紀錄被丟棄，什麼都沒寫。

整串搬移（item 2）的 undo 見上方第 10 步（#369）。結果記在 #335。結束後刪掉拋棄式日曆。

## Release gate：delete_calendar 的 require_empty（#328）

#328 的空檢查（`CalendarEmptiness`、`CountingEventStore`）的純邏輯有單元測試，但「EventKit 對空清單回 `[]`、
讀不到才回 nil」「本機 EventKit 資料裡看得到 150 年前後的事件」這些前提只能在裝置上確認。這是 stateless 的，
**出 #328 的那個版本打 tag 之前**，用剛 build 的 binary 的 `--cli`（見上表；不用 AppleScript），只在名稱含
`#328` 的拋棄式日曆與清單上：

1. 空清單：`delete_calendar` 帶 `require_empty: true` → 刪除，回 `checked_empty: true`、`reminders_found: 0`。
2. 空日曆：同上 → 刪除，回 `searched_from` / `searched_to`；記下整個呼叫的時間（PR #413 時中位數約 0.24–0.31 s）。
3. 只有一筆已完成提醒的清單 → 拒絕（`holds 1 reminder(s), completed ones included`），清單還在。
4. 只在 2150 年與 1850 年各有一個事件的日曆 → 拒絕，日曆與兩個事件都還在（另一次 `--cli` 讀回）。
5. 不帶 `require_empty`、日曆裡有事件 → 照舊刪除，回 `{action, id}`。

結果記在 #328。結束後刪掉拋棄式日曆與清單，用 `list_calendars` 確認沒有名稱含 `#328` 的殘留。

## Release gate：自然的 re-exec（#361）

#361 的 stderr 行與 sentinel 記錄只在 forced 路徑上看過：開發機的 host 有完整授權，會保留自己的 grant，自然的 re-exec
不會發生。`testDefault_followsTheHostsAuthorizationStatus` 依 oracle 斷言，所以也要在沒有授權的 host 上才走得到。

**不要動 TCC 去製造這個環境**：撤銷或重設授權要使用者在場，留給 #382。在一個本來就沒有完整授權的 host 底下：

1. 啟動 server：stderr 有一行 `re-executing so macOS checks CheICalMCP's own Calendar and Reminders grant: <host> had Calendar …, Reminders …`。
2. 同一個 host 底下跑 `--print-tcc-path`：有 `CHE_ICAL_MCP_DISCLAIMED says this process re-executed at start (hostGrantUnusable): …`。
3. 從另一個有完整授權的 host 跑 `--print-tcc-path`：沒有這一行。它只回報自己那次啟動，不回報 server 的。

結果記在 #361。
