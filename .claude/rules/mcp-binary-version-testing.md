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

## Release gate：長期系列的整個系列刪除 undo 與重複防護（#319、#321）

#319 的視窗位置（`SeriesExceptionsPlanner.deleteWindow`）與 #321 的重複防護（系列識別碼與規則時段，
`SeriesRecreations`）只有純函式、記憶體內 store 與原始碼結構的測試。依賴而沒量過的裝置行為：開始於
多年前的系列，刪除前後的場次能在一次查詢內列出且 `/RID=` 照舊；整個系列 undo 重建的系列，其場次讀回
的 identifier 是新系列的 id、`occurrenceDate` 等於規則時段（`OccurrenceSlotGuard.holder` 用它）。undo 是
stateful 的，`--cli` 走不到（見上表），所以**出 #319／#321 的那個版本打 tag 之前**，在重啟後的 session
MCP 上（行為探測確認是新 binary 之後），只用名稱含 `#319` 或 `#321` 的拋棄式日曆。每一步建的系列用自己的
標題（例如「#321 step 4」），因為 `create_event` 會把同一日曆裡 30 秒內同標題同開始的事件當成重複而略過；
每次建立都確認回應是 created、不是 skipped：

1. **#319 舊系列**：`create_event` 建一個開始於約六年前、不設結束的每週系列 → 用 `--cli` 刪掉一個
   未來兩週內的場次（span `this`），再用 `--cli` 改另一個未來兩週內的場次的標題（span `this`，它要留在視窗內；兩個寫入都不進 session
   的 undo stack）→ session：`delete_event` span `all` → `undo`：回應說 1 個場次維持刪除、1 個編輯過的場次
   以一次性事件回來，視窗起訖約為刪除前三年到一年後，並說系列在視窗前後都有場次；`list_events` 讀回：
   被刪的那天沒有場次，被改的那天只有一個（一次性事件，改過的標題）。修正前的 binary 會兩個都依規則回來。
2. **#321 同名的另一個系列**：同一拋棄式日曆建同標題的每週系列 A，再建 B，B 的開始比 A 早一週（S - 7 天，
   之後的場次與 A 同時）；`create_event` 會把 30 秒內同標題同開始的事件當成重複而略過，所以 B 不可與 A 同一個
   開始時間，**確認 B 的回應是 created、不是 skipped** → `delete_event` 刪 A 的第二個場次（span `this`）→ `undo`：
   要寫回一次性事件（修正前回「already restored by its series」、什麼都沒寫）；`list_events` 讀回那個時間有 B 的
   場次與一次性事件各一個。
3. **#321 先 undo 整個系列，再 undo 單一場次（例外擷取到的形狀）**：建每週 ×4 系列 → 刪第三場（span `this`）→
   `delete_event` span `all` → `undo`（系列回來、第三場維持刪除）→ `undo`：第三場以一次性事件回來；讀回第三場那天
   只有一個事件。
4. **#321 由重建系列的新 id 擋下重複（id 比對的佔用分支，唯一能在裝置上走到的形狀）**：建一個開始於約六年前、
   不設結束的每週系列 → session：`delete_event` span `this` 刪掉一個約五年前的場次（它的時段落在
   [刪除 - 1094 天, 刪除 + 366 天) 與其前後一年之外，整個系列刪除時不會列到）→ `delete_event` span `all` →
   `undo`（系列依規則回來，那個五年前的時段也回來）→ `undo`：回應是「already restored by its series」、什麼都
   沒寫；讀回那天只有重建系列的一個場次。記下這次 `undo` 的耗時（它會列出時段前後兩年的行事曆）。
5. **#321 被搬走的場次（第 4 步的變形）**：同第 4 步，但在最後一個 `undo` 之前，用 `--cli` 的 `update_event`
   （重建系列的 id、那天的 `occurrence_date`、span `this`）把那個場次改到三天後 → session 的 `list_events` 先確認
   那個場次確實在三天後（session 看得到這次搬移；看不到就停下來，這一步不算數）→ session `undo`：回應是
   「already restored by its series」、什麼都沒寫；讀回原本那天沒有事件、三天後只有被搬走的那一個場次。
6. **#321 finding 22（rule-less `.deleteEvent` 的防護）**：建一個開始於約九年前、不設結束的每週系列（自己的標題）→
   用 `--cli` 改一個在系列開始後約 4.5 年（也就是刪除前約 4.5 年）的場次的標題（span `this`）。這個時段要同時落在：
   刪除前後的視窗與它前後一年之外（刪除前超過 1460 天）、#319 之前的視窗之外（系列開始後超過 1459 天，所以
   v1.23.0 也擷取不到它）、#416 的掃描之內（系列開始後約五年內，否則那一列會以 past what can be listed 被拒絕）→ session：
   `delete_events_batch` 的 `event_ids` 帶 `[那個場次自己的 id（含 /RID=）, 系列 id]`、span `all`（兩列都要 deleted；
   那個場次的列若被 #416 拒絕，記下來，這一步不算數）→ `undo`：系列依規則回來、那個時段也回來，場次自己的紀錄
   找到系列已佔住它，批次訊息說那個編輯過的場次沒寫入、它的編輯沒有回來；讀回那天只有重建系列的一個場次。
   #321 之前的 binary（v1.23.0）在兩個視窗都擷取不到那個時段，系列依規則把它帶回來後，場次的紀錄又寫一個一次性事件
   （那天兩個事件），所以這一步分得出兩版。
   另外，舊的形狀（場次在視窗內、`[場次 id, 系列 id]`）只當回歸檢查：系列的擷取已經把那個時段算成單獨刪除，
   防護走不到；讀回那天只有一個事件（一次性事件）即可，兩版結果相同。這條防護路徑另有單元測試
   （`SeriesExceptionsUndoTests`、`UndoBatchRestoreTests`），本步是它唯一的裝置檢查。
7. **#319 多個星期幾的次數規則**：建一個開始於約十二年前、每週一三五、共 450 次的系列 → 用 `--cli` 刪掉它的
   第 100 個場次（span `this`）→ session：`delete_event` span `all` → `undo`：回應說 1 個場次維持刪除，讀回該天
   沒有場次。對照：PR #494 第一輪的 binary（branch 上的 commit `8648c70` build 出來的，上界按 450 週算）回應會說依規則
   重建；#319 之前的 binary（v1.23.0）也會套用例外（它的視窗從第一個場次起，涵蓋整個系列）。
8. **split move**：`move_events_batch` span `this` 把每週系列的一個場次移到另一個拋棄式日曆 → `undo`：場次以一次性
   事件回到原日曆、複本被移除（與 #466 相同；#321 只改了防護的比對方式）。
9. **split move 的時段已被佔用（PR #494 第五輪）**：建一個開始於約六年前、不設結束的每週系列（自己的標題）→ session：
   `move_events_batch` span `this`、`occurrence_date` 為約五年前的一天，把那個場次移到另一個拋棄式日曆 B →
   `delete_event` span `all`（系列）→ `undo`（系列依規則回來，那個五年前的時段也回來）→ `undo`（搬移）：回應說
   「was not recreated in its original calendar: its series already holds its original slot there」，複本留在 B、沒有
   被查找或移除。變形：另建一個這樣的系列，搬移前先用 `--cli` 的 `update_event` span `this` 改那個場次的標題，其餘
   相同 → 最後的 `undo` 回應說「the copy the move made (id …) is the only version with that edit」。

另外記錄、不算通過條件的：在 Google（或其他存檔後會換 id 的來源）上做第 4 步時，若重建系列存檔後 id 變了，
第 4 步會寫出第二個事件（已知限制，CHANGELOG 的 Not covered）；有大量事件的拋棄式日曆時，做一次刪掉約 20 個
場次的 `delete_events_batch`（span `this`）再 `undo`，記下耗時。結果記在 #319 與 #321。結束後刪掉拋棄式日曆，
隔一分鐘再 `list_calendars` 一次確認沒有殘留。

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

## Release gate：第 n 週規則移動開始日（#454）

工具寫不出第 n 週規則，所以 PR #462 只讀過程式，沒有跑過。**出 #454 的那個版本打 tag 之前**，由使用者在
Calendar.app 建名稱含 `#454` 的拋棄式日曆與一個「每月第一個週一」的事件，再用剛 build 的 binary 的 `--cli`：

1. span `all`，`start_time` 放在某個週四：要被拒絕，訊息說到行事曆 App 改，不提 `recurrence`。
2. span `all`，`start_time` 放在同一天的另一個時間：要成功，場次還是每月第一個週一。
3. span `all`，`start_time` 放在第二個週一：目前會放行，記下 store 怎麼處理規則。
4. 改成「每月最後一個工作日」（`setPositions`），span `all`，`start_time` 放在某個週六：要被拒絕，訊息同第 1 步。
   週一到週五的起始日都在規則的星期裡，會放行（同第 3 步），記下 store 怎麼處理規則。
5. 第 1 步的系列，span `all` 帶 `recurrence`（`monthly`、`days_of_week: [2]`、`end_date`）、不改起始日：目前會放行，
   規則變成每個週一（第 n 週無法用 `recurrence` 寫出），記下讀回的場次。這不是 regression，但不要在真實系列上這樣結束一個
   第 n 週系列。

結果記在 #454。結束後刪掉拋棄式日曆。

## Release gate：update_event 存檔失敗後的 rollback（#373）

#373 verify 讓 `updateEvent` 在 `eventStore.save` 丟錯時先 `event.rollback()` 再回傳錯誤；這只有
原始碼結構測試（`UpdateEventRefusalOrderTests.testAFailedSaveRollsTheEventBack`）。#274 的探測（2026-11-06）量過
commit 失敗：有沒有 `rollback()` 都不會落地，它只清 `hasChanges`。下面這步量的是 session MCP 上的另一種失敗（唯讀日曆）。這是 stateful 的（同一個 server process 內的下一次
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
   看完就刪掉它），回應的 `alarms_note` 有 #433 的說明，`list_reminders` 讀回到期時間不變、`minutes_before: 15` →
   打開 Reminders.app 看列表：顯示「到期減 15 分鐘」是**已知行為，記錄下來、不算失敗**（#433：2026-11-05 量的 14 列裡，
   顯示到期時間的列都沒有早於到期的鬧鐘；這 14 列都沒有檢查通知）。失敗條件是 `list_reminders` 讀回的到期時間變了。
   列表改成顯示到期時間的話也要回報：行為變了，`alarms_note`、tool description 與 README 都要跟著改。
   再建下面幾筆，到期時間相同（`[1440]` 那筆要**至少兩天後**，否則它的鬧鐘會落在第 9 步等待時）、**標題要不同**
   （同標題同到期會被當成重複略過），逐筆看列表，記錄顯示的時間，看完全部刪掉再做第 9 步：
   - `[-15]`：有 note，列表顯示到期加 15 分鐘（量過，已知行為）；
   - `[15, -15]`：有 note，推得列表顯示到期減 15 分鐘，沒量過；
   - `[-15, -60]`：有 note，推得列表顯示到期加 15 分鐘，沒量過；
   - `[0, -15]`：沒有 note。**這一列決定 `listShowsAlarmTime` 的條件**：量到的列分不出它顯示到期時間還是到期加 15
     分鐘。顯示的不是到期時間，就要回報：規則會變成「最早且不在到期時間上的鬧鐘」，凡是到期時間有鬧鐘、又有更晚鬧鐘的
     形狀都要改（`[-15]` 加到期時間的絕對鬧鐘、`[0]` 加較晚的絕對鬧鐘也在內），不只 `[0, ...]`；
   - `[1440]`：跨到前一天，有 note，記錄列表的日期，以及它出現在哪個智慧清單（沒量過）。
   絕對鬧鐘與相對鬧鐘並存的三個形狀都是推得的，14 列沒有量過，工具也寫不出絕對鬧鐘：
   - `[-15]` 加到期時間的絕對鬧鐘：沒有 note（`listShowsAlarmTime` 把絕對鬧鐘算進去），推得列表還是到期時間；
   - `[15]` 加更早的絕對鬧鐘：有 note，推得列表顯示那個絕對鬧鐘的時間；
   - `[0]` 加更早的絕對鬧鐘：有 note，推得同上。
   這三個形狀要用未 commit 的本機探針寫絕對鬧鐘（#433 的量測就是這樣做的）；沒有探針時記成沒驗，不算通過。
   不要用帶 Early Reminder 的提醒代替：列表結果不同時分不出是哪一個造成的。
   Early Reminder 另外看（手動，#433 只看過一筆，沒有對照組）：同一拋棄式清單手動建兩筆帶時間的提醒，一筆有 Early
   Reminder、一筆沒有，比較 `list_reminders` 讀回；再對有 Early Reminder 的提醒分別做 `due_date`、以及同一次呼叫帶
   `due_date` 與 `realign_to_due`（這兩條路徑才會重寫絕對鬧鐘；單獨帶 `realign_to_due` 時鬧鐘已在到期時間，不會重寫，
   `alarms_minutes_offsets` 也不碰它），回 App 看 Early Reminder 還在不在。
   只帶 `due_date` 改期一筆帶 `[15]` 的提醒 → 回應有 `alarms_note`；只改標題 → 沒有。
9. 建一個到期在幾分鐘後、帶 `[2]` 的提醒，等到它的通知：要在到期前 2 分鐘出現一次，記下橫幅顯示的時間。
   **第一個橫幅出現後就關掉它**，再等到到期時間：2026-11-05 第一個橫幅還在畫面上，到期時有沒有第二個通知沒有量到。
   到期時有或沒有通知都**記錄下來、不算失敗**，兩邊的文字（`alarmDisplayNote`、README、CHANGELOG）都要照結果改；
   這一步要驗的只是那個提前 2 分鐘的相對鬧鐘有沒有響，到期前 2 分鐘沒有通知才算失敗。

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

## Release gate：move by copy 的 undo（#466）

#466 的 undo（先還原原事件、副本找得到又沒被改過才移除）只有純函式與原始碼結構測試，加上單一 stdio process
的裝置檢查（iCloud）。undo 是 stateful，`--cli` 走不到。這一節是 tag 之前**必須**做完的步驟（PR #474 round 2 的
verify 把 session MCP 端到端檢查列為缺口），沒做完不能 tag。**出 #466 的那個版本打 tag 之前**，在重啟後的 session
MCP 上（行為探測確認是新 binary 之後），只用名稱含 `#466` 的拋棄式日曆 A、B，系列用 `--cli` 建：

1. 每週 3 次的系列在 A → session：`move_events_batch` span `this` 把第二個場次搬到 B（`method: split`）→ `undo`：
   原場次以一次性事件回到 A（訊息有 new ID），B 的副本被移除；
2. 同上，但搬移後等至少 60 秒、什麼都不改 → `undo`：副本被移除（以 `changed` 留下副本，就是有欄位在同步後自己變了，
   記下欄位、回報；原事件仍要回來）。再做一次，副本帶 location、email 或 sound 鬧鐘，以及全天事件；
3. 搬移後用 `--cli` 改副本的標題 → `undo`：原事件回來，副本留在 B，訊息列出 `title`；
4. 搬移後用 `--cli` 刪掉副本 → `undo`：原事件回來，訊息說副本找不到；
5. 有第二個帳號時，把 B 換成另一個帳號的拋棄式日曆，重做第 1、2 步。
6. 搬移後用 `--cli` 把副本改到第三個拋棄式日曆 C → `undo`：原事件回來，訊息列出 `calendar`，不說副本在 B；
   搬移後刪掉 A → `undo`：以「the move of an event」與「the copy the move made stays in the calendar it was moved to,
   if it is still there」拒絕，什麼都沒寫，`discard_id` 移除。
7. 同名系列佔住時段（#285 的 `seriesHoldsSlot` 不比對系列 id）：在第三個拋棄式日曆建同標題、同時間的每週系列，用
   `--cli` 的 `move_events_batch` span `all` 搬進 A（同一日曆內 `create_event` 會回既有系列，造不出第二個）→ split →
   `undo`：原場次不重建、副本留在 B，訊息說「was not recreated」與「kept」。2026-11-08 在單一 stdio process 量過。
8. 搬移後在 Calendar.app 替副本加受邀者 → `undo`：原事件回來，副本留下，訊息說「has attendees now」（沒有量過；
   `--cli` 加不了受邀者）。
系列自己重新佔了那個時段（整串刪除的 capture 失敗後從規則重建）也走第 7 步的路，副本同樣留下；這個形狀沒有量。
fallback copy（in-place 失敗後的複製）在裝置上誘發不了，沒有量；它與 split 走同一個紀錄與同一個 undo arm。

結果記在 #466。結束後刪掉拋棄式日曆，用 `list_calendars` 確認。

## Release gate：create_reminder fallback 第二次存檔失敗後的 rollback（#308）

#308 讓 timed `create_reminder`（與 `create_reminders_batch` 的 timed 列）存檔後讀回；讀回時 due
掉了時間或時區，就跑 #237 fallback，把這筆**已經存進 store** 的提醒事項再存一次，失敗時呼叫
`reminder.rollback()`、回報 `aligned: false`。單元測試（`ReminderCreateWriteTests`）只看得到
`rollback` 有被呼叫。#274 的探測（2026-11-06）已回答：`EKObject.rollback()` **不會**丟掉已在 store 的
提醒事項上待存的改動，下一次存檔仍會寫入（見 `ExistingReminderSave`，那裡也寫了為什麼不用
`EKEventStore.reset()`）。所以這次 fallback 存檔失敗時，改動可能隨下一次存檔落地。

前提是要有一個「存檔後會丟掉 due 時區」的來源；iCloud 會保住時區（2026-11-05 實測，timed create
讀回 `aligned: true`），所以在 iCloud 上 fallback 根本不會跑，這一步無法在 iCloud 誘發。**出 #308
的那個版本打 tag 之前**：

1. 若手邊有已知會丟時區的來源（#237 的紀錄只確認 iCloud 與 Exchange 會保住），在該來源名稱含
   `#308` 的拋棄式清單上做 timed `create_reminder`，記下 `date_sync`；看 stderr 有沒有
   `create_reminder: the saved due date read back without its time or zone` 這行。
2. 沒有這樣的來源時，這一步不能在裝置上做，fallback 這條路徑上的失敗沒有誘發過，release note 照 CHANGELOG 的寫法說明。

結果記在 #308。結束後刪掉拋棄式清單。

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

## Release gate：event lookup raise（#288）

#288 的 `CheICalEventWithIdentifier` 只有 raise 從 Objective-C 來的單元測試（`CheICalRaisingEventStore`，debug build）。
raise 穿過 EventKit 之後 store 還能不能用、undo history 在不在，要在常駐 process 上才量得到，`--cli` 結構上驗不了
（見上表）。測試時種類檢查擋在前面，權限都給時走不到這個呼叫，所以要在本機暫時關掉（不 commit），用 **release build**
（出貨的 optimization level），arm64，單一 stdio process，每次呼叫設 timeout，只用名稱含 `#288` 的拋棄式日曆與清單：

1. 建提醒事項，再建事件，留下一筆 undo 紀錄。
2. 用提醒事項的 id 呼叫 `update_event` 兩次：都回查詢失敗（may still exist、不要重建），process 活著。
3. `undo`：刪掉第 1 步的事件。
4. `create_event` 再 `update_event`，走一次 save。
5. `update_reminder` 那筆提醒事項：讀得到，仍是提醒事項。
6. 迴圈 raise 約 1000 次：沒有 hang。記憶體和同樣次數、不會 raise 的 not-found 對照（2026-11-06：每個 raise 約 6 KB，
   不回收，不 raise 時持平；這是 EventKit frame 裡的物件，修不了，只要沒有明顯變大就算過）。
7. 結束 process，用新 process 列出：沒有多出事件，提醒事項不變。stdio 有 read-after-write 問題，跨 process 的讀取放在結尾。

2026-11-06 已在 iCloud 做過第 1 到 7 步（release、arm64），結果記在 #288。**沒做，出版前要補**：

- **x86_64 slice**（Rosetta 或 Intel Mac）：同樣步驟跑一次。
- **Reminders 權限真的被拒絕，以及 `calendarItem(withIdentifier:)` 在那個狀態下回傳什麼**：見 #382 的留言，由使用者撤銷權限後在場執行，
  種類檢查不用關。`calendarItem` 沒有被包住，raise 的話 process 仍會結束。

結果記在 #288。結束後刪掉拋棄式日曆與清單。

## Release gate：場次自己的 id 上的 span all（#416）

#416 的拒絕只在 iCloud 量過，判斷靠 `isDetached` 或 id 裡的 `/RID=`，以及從 `/RID=` 前面那段 id 列出系列。#320 在 Google
量到這兩者可靠，Exchange 沒有量。**出 #416 的版本打 tag 之前**，用剛 build 的 binary 的 `--cli`：第 1–4 步在有 Google 或
Exchange 帳號時，在該來源名稱含 `#416` 的拋棄式日曆上做；**第 5–7 步在 iCloud 上一律要做，不以有第二個帳號為前提**。每個形狀
都用**新的系列與獨立的 title 前綴**（共用前綴會把兩個系列混在一起，2026-11-05 踩過），每週 5 場，逐場比對 title、start、
end、notes、location、alarms。

1. 一次性事件：`update_event` 與 `delete_event` 都帶 span `all`，要成功；`update_event` 帶 span `future` 也要成功。若被拒絕
   （「reported as one occurrence」），就是該來源把一次性事件回報成 detached，要回報；這個情況只有 span `this` 走得通；
2. 每週 5 次的系列，單獨改第 3 場 → 用該場次的 id 帶 span `all` 的 `update_event` 與 `delete_event`：要被拒絕，
   系列不變。若沒被拒絕，就是該來源的 `isDetached` 沒有設，要回報。再用系列 id 加第 3 場的 `occurrence_date`、span `future`
   寫 `start_time`：單獨改過的場次在該來源若沒有自己的 id，會被 `resolvedOccurrenceRefusal` 拒絕；
3. 新建一個系列，單獨改第 1 場的標題與備註、再把時間 +2h → 用第 1 場的 id：先 `delete_event` span `all`，要被拒絕；再
   `update_event` span `all` 只改 `location`：iCloud 上全部場次都有 `location`，每一場的 title、start、end、notes 都不變；
   最後 `delete_event` span `future`，整個系列刪除。該來源的 id 沒有 `/RID=` 時 span `all` 的 update 會被拒絕（列不出系列），
   這是已知限制，記下來，不算 bug；
4. 新建一個系列，第一場刪掉、第二場與第四場單獨改過（第二場改時間、第四場改標題與備註）→ 用第二場的 id 帶 span `all` 只改
   `location`：iCloud 上全部場次更新、新 id，其他欄位不變（2026-11-05）。再新建一個系列，單獨改第 3 場的標題與備註、再把時間
   +2h → 用它的 id 帶 span `future` 只改 `location`：第 1、2 場不動，第 3 場起 `location` 寫入、新 id；
5. **放行清單**（2026-11-06，iCloud，系列 10:00–11:00）：
   (a) 用第 1 場（時間 +2h）與第 3 場的 id，span `all`、`future`，`start_time`、`end_time`、`all_day`（`true` 與 `false`）、
   `timezone`、`clear_timezone`、`url`、`alarms_minutes_offsets`、`structured_location`、`calendar_name`（同帳號）、
   `clear_recurrence`：全部拒絕、系列不變；
   (b) 新值：第 1 場改標題、備註、地點、+2h，span `all` 寫 `title`、`notes`、`location`：別的場次都拿到新值，其他欄位不變，
   第 1 場保留其他自己的值；`recurrence` weekly 不帶 `days_of_week`：新規則生效，別的場次不變；第 3 場 span `future` 同樣（只改
   過標題、備註、時間，沒有自己的地點或鬧鐘時）；
   (c) 相同值：第 1 場地點 R101，span `all` 寫 R101；第 3 場 span `future`；title、notes 各一次：全部拒絕。沒有這個拒絕的 build
   回 `updated`、別的場次沒變；
   (d) 帶到新系列：第 3 場有自己的地點或鬧鐘，span `future` 只寫 `title`；第 1 場刪掉、第 2 場有自己的地點，span `all`：都拒絕。
   沒有這個拒絕的 build 上新系列帶著它的地點與鬧鐘（`url`、標題、備註、時間不會帶）。第 3 場只有自己的地點（沒有鬧鐘）時，span
   `future` 寫新的 `location`：放行。第 1 場（含移過時間 +2h 的，也含全天每週系列）span `all` 只寫 `title`：放行，地點與鬧鐘不動。全天系列的
   `/RID=` 是當地日期讀成 UTC，非 UTC 主機若當瞬間比，第 1 場會被當成已刪；再用 `TZ=America/Los_Angeles` 跑一次；
   (e) `days_of_week`：第 1 場移到週三，寫 `[週三]` 被拒絕（沒有這個拒絕的 build 在週三留下兩場），寫 `[週一]` 放行；
   (f) 系列 id、span `all`，第 3 場或第 1 場改過時的預期結果：別的場次都拿到新值，**單獨改過的場次保留改過的內容**：
   `start_time` 09:00：只改結束的場次 09:00 起、保留自己的長度；+2h 的場次留在 12:00；移到週三的場次留在週三、09:00 起。
   `end_time` 12:00：只改結束的場次不變；+2h 的場次到 14:00。`timezone`：每場位移相同，與沒有單獨改過場次的系列一樣。
   `title`、`notes`、`location`：第 3 場只改時間、第 4 場改標題與備註、第 5 場改地點：改過那一欄的場次留著自己的值，其他都拿到新值。
   `clear_timezone`：有次數上限的系列拒絕，什麼都不寫（沒有這個拒絕的 build 會少掉最後一場，沒有單獨改過場次也一樣，#455）；結束日期或沒有結束的系列放行，每場都在。
   `clear_recurrence`：剩系列第一個日期的一個事件，單獨改過的場次消失。`calendar_name`（同帳號）：全部搬走。`url`、鬧鐘、
   `structured_location`：寫到別的場次。`all_day`：系列有單獨改過的場次時拒絕，什麼都不寫；沒有這個拒絕的 build 會多一個場次（#442）。
   **#478 之後**：系列已開始（第 1 場的原時段在現在之前）時，`timezone`（與事件原本不同的時區）與 `clear_timezone` 經系列 id、span `all`
   會在寫入前被拒絕，系列不變；這是預期結果，不是 regression。上面 `timezone` 那一句描述的是舊行為，要看它，用一個還沒開始的系列（第 1 場在未來）重做；`clear_timezone` 那一句
   已照 #455 改寫（有次數上限的系列拒絕，有結束日或沒有結束的未開始系列放行），照它做；(g) 從還沒發生的下一場用 span `future` 帶 `timezone` 仍放行（#478 量過）。
   **系列 id 走到第一場（#428）**：第 1 場只改標題或結束（開始時間沒動），或第 1 場刪掉、第 2 場單獨改過時，系列 id 帶 span `all` 的
   `update_event`、`delete_event`、`delete_events_batch`（`event_ids`，含 dry run，#436）改走該場次自己的 id：見 (h)。`id` 是系列 id
   （第 1 場刪掉時是新 id），回 `occurrence_id`。span `future` 在這個形狀仍被拒絕。#436 是在 Google 帳號上量到的，那裡要再跑一次
   刪除（`create_calendar` 只建在預設來源，要手動建拋棄式日曆）。`move_events_batch` span `all` 可搬同帳號的日曆，整個
   系列搬走，要走一次；
   (g) 系列 id 加下一場的 `occurrence_date`、span `future`：`start_time`、`end_time`、`timezone`、`url`、鬧鐘、
   `structured_location` 只動後面的場次；`all_day`、`clear_recurrence`、`calendar_name` 不是（#451），訊息不給這條路；
   (h) 封閉清單（#428，iCloud，2026-11-06 量測，2026-11-08 verify r1 收窄成量過的格子）：有時間的系列、每週重複、每週至多一天，
   場次在原本的開始時間、和沒改過的場次只差在標題、備註、地點或鬧鐘，每次呼叫只帶一個欄位（或 `start_time` 加 `end_time`），
   日期只改當天的時刻（verify r2：量過的每一列都是這樣，改到別天或別的星期拒絕）。
   量過、放行的格子：`start_time`、`end_time`、`all_day: true`、鬧鐘，在第 1 場 span `all`、第 1 場刪掉時第 2 場 span `all`（`all_day: true`
   除外：verify r7 起拒絕，#471 量到這種從較後時段的存檔會掉場次）、
   第 3 場 span `future`（`all_day: true` 除外：verify r8 起拒絕，#451 的 laterOccurrenceRefusal 本來就拒絕它）、開放式系列、
   另有場次改過的系列（改過的場次保留改過的內容，`all_day` 不多出場次）；`timezone`、`url`、
   `structured_location` 只在第 1 場 span `all` 與第 3 場 span `future`，5 場、沒有其他改過的場次。鬧鐘只在場次的鬧鐘與系列相同時。
   `timezone` 在已開始的系列上由 #478 的 zoneRefusal 在內層呼叫裡拒絕（#478 合併後 2026-11-08 量過：經系列 id 與經第 1 場自己的 id，
   10 場都不變；#428 r7 自己那道拒絕因此拿掉）。在 #478 之前量到的情況（verify r7，2026-11-08：從 2026-09-07 起每週 10 場的臺北 07:30 系列
   改成 Europe/London，已發生的 10/26、11/02 變成 08:30，最後一場 11/09 不見；主物件路線同樣如此，即 #478）。從還沒發生的第 3 場用
   span `future` 經它自己的 id 寫 `timezone`（verify r9 重量，2026-11-08）：只有第 3 場改過、第 1 場沒改時放行，10 場都在、時刻不變
   （沒有跨 DST）；第 1 場也改過（#428 的形狀）時被 #428 的檢查拒絕（另有改過的場次），10 場不變。經第 1 場自己的 id 帶 span `all`：
   #478 拒絕，訊息的 span `future` 那句換成這個形狀沒有從某天起的路，10 場不變。（#478 合併時的紀錄把第一種寫成第 1 場也改過的形狀，是錯的。）未開始的系列跨 DST
   改 London：6 場都在、London 牆上時間不變，與主物件路線相同。
   第 1 場刪掉、第 2 場（已發生）改過的已開始系列，經系列 id 的同日 `start_time`、`end_time`、鬧鐘：4 場都照說的改、新 id
   （2026-11-08）。
   第 3 場 span `future` 的 `url`、`timezone` 在 2026-11-08 重量一次：第 3 場起拿到新值、新 id，第 1、2 場不動。這兩列都是還沒
   開始的系列（12/07 起）；已開始的系列：`timezone` 由 #478 的 zoneRefusal 判斷（看寫入起點的場次是否已發生），從還沒發生的場次放行；
   但在 #428 的形狀（第 1 場單獨改過）下，第 3 場自己的 id 帶 span `future` 會因另有改過的場次（第 1 場）被 #428 的檢查拒絕（見上）。`url` 照舊。
   **沒量、拒絕**：其他規則（M/W/F、每月、隔週）、全天系列、其他欄位組合、日期加 `title` 或 `recurrence`、改到別天的日期、上面沒列的格子。
   經系列 id 被拒絕時，訊息說是經系列 id、不指回系列 id。第 1 場刪掉、其餘全部改過時，系列 id 的 `delete_event` span `all` 也刪光（2026-11-08）。
   第 1 場有自己的地點或鬧鐘時 span `all` 放行、地點與鬧鐘留在第 1 場；會另起新系列時拒絕，同 (d)。`clear_timezone`、
   `clear_recurrence`、`calendar_name`、全天系列的 `all_day: false` 拒絕：在沒有這些拒絕的 build 上，分別是別的場次移位且少一場、
   回 `updated` 沒改、span `future` 搬走全部 5 場、別的場次時間不對且多一場；所以經場次 id 的 `all_day: true` 沒有路改回。
   `days_of_week` 系列，第 1 場的 id 帶別的星期的 `start_time`：weekday 拒絕。經系列 id 寫過 `start_time` 後，第 1 場的 `/RID=`
   留在原本時段（2026-11-08），之後經它的日期寫入被拒絕、`title` 照常（量過）。經系列 id 的 `delete_event` span `all`：5 場、
   開放式、第 1 場刪掉加第 2、4 場改過的開放式，刪完列七年都是 0（2026-11-08）；span `this` 只刪一場、span `future` 拒絕。
   第 1 場刪掉、第 2 場改過時，經系列 id 的 `title`、`notes`（2026-11-08）與 `location`（#416 第 4 步）放行、新 id；`recurrence`
   拒絕（verify r3：會從較後的時段另起新系列，#443 量到 count 會少）。最早改過的場次開始時間晚於下一場的時段時，系列 id 不走這條路
   （2026-11-08：第 2 場移到第 3 場之後，update 與 delete 都回 edited-before 的拒絕，什麼都沒動）。
   **已經開始的系列（#471 合併後，2026-11-08 量過）**：每週 5 場、第一場已過、第 1 場只改標題。經系列 id 的 span `all`：
   別天的 `start_time` 被 #428 的同日規則拒絕；`recurrence` 換星期（`days_of_week` 含原日）與 interval 2 被 #471 的
   startedRuleRefusal 拒絕，什麼都沒動；同一天的 `start_time`、`end_time`、`all_day: true`、`timezone`、保留樣式加 `end_date`
   的 `recurrence` 都照說的套用到每一場（含已過的那一場，日期不變）。經第 1 場自己的 id 的同日 `start_time`、`end_time`、
   `all_day: true` 也一樣。所以 #428 r4/r5 對已開始系列的拒絕拿掉，交給 #471 的檢查（它們在內層 `updateEvent` 裡、任何寫入
   之前執行，`SeriesIdRouteWiringTests` 固定這個順序）。
   **打 tag 前必做（verify r4 的 MEDIUM，仍欠）**：在重啟後的 session MCP 上，先做一筆可 undo 的操作，再做這條經系列 id 的刪除，
   第一次 `undo` 要被拒絕並丟棄刪除紀錄，第二次 `undo` 要還原先前那筆（`--cli` 走不到）；
   (i) 搬移（#426，2026-11-06，iCloud，同帳號）：第 3 場改過，用它的 id：`move_events_batch` span `this` 不帶日期、帶別的日期：拒絕，
   5 場都在原日曆；帶它自己的日期：`split`，它到目標日曆成單一事件，原日曆 4 場。span `all`：全部搬走，id 不變，在 session MCP 上
   `undo` 搬回來；span `all` 帶日期：拒絕。`copy_event` 的 `delete_original`：拒絕。`update_event` span `this` 帶同帳號的新日曆，
   經場次自己的 id、經系列 id 加 `occurrence_date`：都拒絕，帶目前的日曆放行；
   (j) Google 帳號（#435，只在該帳號上有意義，在兩個拋棄式日曆上做）：`create_event` → `move_events_batch` 到同帳號另一日曆
   （`id_changed: true`）→ `undo`：訊息帶新的 ID → `undo`：刪掉事件，不是 not found。都在同一個 session MCP 或 stdio process；
6. `delete_events_batch` 的 `event_ids` 帶 `[系列 id, 第 1 場自己的 id]`、span `all`，第 1 場**只改標題**（開始時間沒變，這時
   系列 id 單獨呼叫時走第一場，#436）。先用 `--cli` 帶 `dry_run: true`：列出兩列、沒有拒絕。**真的刪除要在重啟後的 session MCP
   上做**（`--cli` 的 undo stack 隨 process 消失，上面的表）：回 2 succeeded、沒有剩下；接著 `undo` 一次：系列與場次都回來，
   訊息裡「一個場次留在已刪除」與實際還原的是同一個場次（這個順序的 undo 沒有在裝置上跑過）。第 1 場刪掉、第 2 場只改標題的
   形狀同樣走一次。span `this` 帶系列 id：dry run 與實際都回 `occurrence_date` 那一句；
   **#436 經第一場刪除（session MCP）**：先在 session 裡做一筆可 undo 的建立，再用 `--cli` 建一個一次性事件與一個系列、用 `--cli` 只改第 1 場的標題（都不進 session 的 undo stack）；`delete_events_batch` 的 `event_ids` 帶 [系列 id, 一次性事件]、span `all`：dry run 那一列有 `occurrence_id` 與 `undo_note`，實際回應有 `through_first_occurrence` 與 `undo_note`；`undo` 一次只把一次性事件還原、系列不回來。再用 `--cli` 建一個同形狀的系列，只帶 [系列 id]：第一次 `undo` 要被拒絕並丟棄這筆，第二次 `undo` 才還原最早那筆建立（沒在裝置上跑過）；
7. 超出掃描範圍：開始日超過五年前的每週開放式系列，單獨改最近一場 → 用它的 id 的 `update_event` span `all`、`delete_event`
   span `all`、`delete_events_batch`（含 dry run）：都拒絕、系列不變，訊息是「past what can be listed」；用系列 id 帶 span `all`
   更新 `location` 與 `start_time`，再刪除：都走得通（2026-11-06，2020 年開始的系列）。

結果記在 #416。結束後刪掉拋棄式日曆，隔一段時間再 `list_calendars` 一次：iCloud 曾把剛刪的日曆以新的 id 帶回來
（2026-11-05，空的）。

## Release gate：event_ids 搭配 span this / future 的 dry run 與實際刪除（#452）

#452 讓 `delete_events_batch` 以 `event_ids` 搭配 span `this` / `future` 時，dry run 與實際呼叫走同一個
`BatchRowSequence`。單元測試只到 handler 與 `SeriesModel`；「場次自己的 id 以 span `future` 刪除後，系列從該時段起
被刪掉、較晚場次自己的 id 不再解析得到」原本只在依日期範圍時於 iCloud 量過（2026-10-20）；依 `event_ids` 在 2026-11-09 用 repo 內 build 的 binary 量過（見本節末），用出版的 binary 重跑還沒做。這是 stateless 的，**出 #452 的
那個版本打 tag 之前**，用剛 build 的 binary 的 `--cli`（見上表），只在名稱含 `#452` 的拋棄式日曆上，每個形狀用新的系列：

1. 一次性事件 A：`event_ids: [A, A]`、span `this`，dry run 第二列 `error` 是 `Event not found: an earlier row of this call
   deleted it` → 實際呼叫 `succeeded: 1`、`failed: 1`，`failures` 的那一列同一句；
2. 每週 5 場的系列，單獨改第 2 場與第 4 場的標題 → `list_events` 取兩者自己的 id（`/RID=`）→ `event_ids: [第 2 場, 第 4 場]`、
   span `future`：dry run 第一列有 `also_deletes_later_occurrences: true` 與 `undo_note`、第二列 `covered_by_earlier_row: true`
   （帶日期，因為先查詢）、頂層 `covered_by_earlier_rows: 1`、沒有 `already_removed` → 實際呼叫 `succeeded: 1`、`failed: 0`、`already_removed: 1`、
   `following_occurrences_deleted` 只列第 2 場、有 `undo_note` → `list_events` 只剩第 1 場；
3. 同樣的系列，順序反過來（`[第 4 場, 第 2 場]`）：兩列都刪除，兩邊都沒有 `already_removed`，只剩第 1 場；
4. 同樣的系列，span `this`、`[第 2 場, 第 4 場]`：兩列都刪除、沒有標記，剩 3 場。
5. 同樣的系列（新建），`[第 2 場, 第 2 場的 id 把 /RID= 後的數字加一週的秒數再加 1]`、span `future`：第二個 id 從來不存在，
   dry run 第二列是 `error`、沒有 `already_removed` → 實際呼叫 `succeeded: 1`、`failed: 1`、沒有 `already_removed`。
   若實際呼叫把它算進 `already_removed`，就是呼叫前的查詢讓不存在的 `/RID=` 解析成別的東西，要回報。
6. 從第一個場次切（新建系列，單獨改第 1 場與第 3 場的標題）：(a) `[第 1 場, 第 3 場]`、span `future`：dry run 第二列
   `covered_by_earlier_row: true` → 實際呼叫 `succeeded: 1`、`already_removed: 1`，`list_events` 一場都不剩；
   (b) 再新建同樣的系列，`[第 1 場, 第 3 場的 id 把 /RID= 後的數字加 1]`、span `future`：記下 dry run 第二列與實際呼叫
   `failures` 的 `error` 原文，兩邊都要失敗、都沒有 `already_removed`。第 5 步只在系列還留著時試不存在的 id；這一步在系列
   整個被刪掉之後試，若不存在的 `/RID=` 在其中一種狀態下解析成系列本身，兩邊的原文會不同（例如 `For recurring events,
   occurrence_date is required` 對 `Event not found`），要回報。
7. **沒有量過**：場次被移離原本的時段，使顯示的開始時間與時段的先後不同（例如把第 4 場移到第 2 場的前一天，再
   `[第 2 場, 第 4 場]`、span `future`；或把負責刪除的第 2 場移到第 4 場顯示的開始時間之後）。
   dry run 的 `covered_by_earlier_row` 與實際呼叫的 `already_removed` 是否仍對得上，`SeriesModel` 沒有建模；有空時量一次，
   記下兩邊的列，對不上就回報。

若第 2 步的實際呼叫回 `failed: 1`、`Event not found`（不是 `already_removed`），就是 `/RID=` 的時段比對在該來源不成立，
要回報到 #452。2026-11-09 已在 iCloud 用 repo 內 build 的 binary（Developer ID 簽章、`--cli`）做過第 1–4 步；verify r1 修正後（先查詢再算 `already_removed`、`undo_note`）重做第 1–5 步，五步都如上；verify r2 修正後（`covered_by_earlier_row`）重做第 2、5、6 步，都如上；第 5 步與第 6(b) 步兩邊的原文都是 dry run `Event not found: <id>`、實際呼叫 `Event not found`（結果見 #452 的 Verify-fix）；出版前用出版的 binary 再做一次。結果記在 #452。結束後刪掉拋棄式日曆，隔一段時間再 `list_calendars` 一次。

## Release gate：行事曆操作與單純 copy_event 的 undo 紀錄（#273）

#273 的紀錄點（`createCalendar`、`updateCalendar`、`deleteCalendar`、`copyEvent`）只有原始碼 pin，undo 的拒絕與丟棄只在
未授權的 store 上用 handler 測試跑過。undo 是 stateful，`--cli` 走不到（見上表）。**出 #273 的那個版本打 tag 之前**，在重啟後的
session MCP 上（行為探測確認是新 binary 之後），只用名稱含 `#273` 的拋棄式日曆：

1. 在拋棄式日曆建一個一次性事件（對照的舊紀錄）→ `create_calendar` 建第二個拋棄式日曆 → `update_calendar` 改它的名稱 →
   `delete_calendar` 刪掉它 → `undo_history` 最上面三筆由上而下是 `Deleted calendar`、`Updated calendar`（舊名稱）、
   `Created calendar`，都帶 `(undo not available)`。
2. `undo` 三次：每次都拒絕、訊息不含日曆名稱、說下一次 undo 會復原更早的那筆，什麼都沒寫；第三次之後 `undo_history` 最上面是
   第 1 步的事件。第四次 `undo` 才刪掉那個事件。
3. 對同名再 `create_calendar` 一次（回傳既有日曆）：`undo_history` 沒有多一筆。
4. 單純 `copy_event` 把一個一次性事件複製到另一個拋棄式日曆 → `undo` 刪掉複本，原事件還在；再複製一次，在 Calendar.app 改複本
   的標題 → `undo` 以 `title` 拒絕、紀錄保留、`discard_id` 可移除。

結果記在 #273。結束後刪掉拋棄式日曆，用 `list_calendars` 確認。
