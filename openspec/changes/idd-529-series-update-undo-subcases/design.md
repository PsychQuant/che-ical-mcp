## Context

#263（PR #519）讓 `undo` 還原一種循環事件修改：iCloud 上經系列自己的 id、span `all`、只寫 `title`、`notes` 或 `location` 的 `update_event`。紀錄在存檔前後各列一次系列的例外（單獨刪除與單獨修改過的場次），undo 先核對系列和修改留下的狀態一樣，再用一次 span `all` 的存檔寫回舊值，最後讀回比對。

這個形狀裡有三類情況在審查時先被排除（#529）：有座標的地點（A）、不在 follows／keeps 兩種形狀裡的場次（B）、第一個場次被單獨修改或刪除（C）。排除的理由當時都是「沒量過」。

#529 的 Diagnosis 補了量測。條件：2026-11-13，iCloud，`ba98641` 的 release build 經 `--cli`，40 個系列，每格一個系列（另註者除外），每個系列在最後一次寫入至少 60 秒後重讀都沒變。**量的是 forward `update_event` 的兩個方向，沒有跑過任何一次 `undo`。** 與本設計有關的結果：

- 經系列物件的整串寫入（32 個系列）：單獨修改過的場次在某欄的值等於系列當時的值就跟著變，否則保留。三個欄位相同。沒有出現「自己的值被取代」「持有舊值卻沒跟」「沒寫的欄位變了」。
- 場次本來就持有寫入的值時（每欄 2 次）：forward 不變，反向寫入把它蓋成系列的舊值。
- `location` 字串寫在有座標的系列地點上：系列與持有系列地點的場次都失去座標與半徑；之後寫 `structured_location`（單獨，或與 `location` 同一次呼叫）把標題、經緯度、半徑放回。
- 場次的地點只要和系列的不同（即使只差座標），兩個方向都保留：store 比的是整個地點。
- 寫入的字串等於地點標題時，什麼都不變。
- 第一個場次被單獨移動（後 1 小時、後 1 天、前 1 小時、移到第二場之後）：回應沒有 `occurrence_id`、title 是系列的；結果與一般系列相同，id 不變。
- 第一個場次被單獨修改、仍在原時段：走 #428，寫入物件是那個場次；它自己持有的欄位會被 forward 直接取代。
- 第一個場次被刪、下一場沒改：#326 拒絕，沒有 update。下一場改過：起新系列、id 換新。

限制：

- 這個 repo 的 undo 是有狀態的，`--cli` 走不到。undo 這一側只能用單一 stdio process 或重啟後的 session MCP 驗。
- PR #531（#527）也改 `SeriesUpdateUndo.swift`、README、CHANGELOG 與 gate 檔，預計先合併。
- 四個範圍上的選擇是協調者依 #522 已接受的順序取的預設（#529 的 Decision record），不是維護者的回答。

## Goals / Non-Goals

**Goals:**

- 有座標的系列地點被 `location` 整串覆寫之後，`undo` 把地點的標題、座標、半徑放回，並用讀回證明。
- 第一個場次被單獨移動的系列，整串修改可以 undo，前提是紀錄路徑走過且每一步成立。
- 每一種維持拒絕的形狀都有量到的理由，寫在閉集文字裡。
- 閉集文字只有一個來源（Swift 常數），每一份重述都由測試釘住。

**Non-Goals:**

- 單一場次的寫入（span `this`）。B(i) 與 C1 裡第一個場次自己的值因此不還原，移到 #522 的 Stage 5。
- undo 經 #428 或 stand-in 的寫入路徑（C1、C3b），同樣移到 Stage 5。
- iCloud 以外的來源、列不完的系列、其他欄位（#522 的 Stage 2 到 4）。
- 還原行事曆 App 另外存在地點上的東西（地址、地圖項目）：這個 server 讀不到，也無從比對。
- `update_event` 本身的行為。

## Decisions

### 地點還原：location 與 structured_location 在同一次存檔寫回

紀錄的 `old` 快照已經有地點的標題、緯度、經度、半徑。當 update 寫了 `location` 而系列的舊地點有座標時，undo 的寫入集合是 `location` 加 `structured_location`，由既有的 `EventSnapshot.applyRestoring` 在一次 span `all` 的存檔裡完成。讀回時 `readBackMismatch` 對系列與每個列出的單獨修改過的場次比對地點的四個值，座標與半徑精確比較。

為什麼不分兩次存檔：量到同一次呼叫就能放回（4 個系列），兩次存檔之間的狀態沒有任何檢查能涵蓋。為什麼不只寫 `structured_location`：量到單獨寫也行（1 個系列），但 undo 寫回的欄位應該是 update 寫的欄位加上它連帶改掉的地點，兩者一起寫與 `applyRestoring` 的既有順序一致。

舊地點沒有座標時，行為和現在一樣（只寫字串）。

### 系列地點的可記錄條件

寫 `location` 時，系列的舊地點必須是下列兩種之一，否則維持 marker。這是封閉列舉，只有這兩種，不得依性質相似類推：

1. 沒有地點，或地點標題等於 location 字串、沒有座標、沒有半徑：undo 寫字串。
2. 地點標題等於 location 字串、有座標（有沒有半徑都可以）：undo 寫字串與地點。

維持 marker 的：地點標題和 location 字串不同（用工具建不出來，沒量過）；有半徑而沒有座標（沒量過，寫字串會丟掉半徑）。

### 單獨修改過的場次：location 比整個地點

`occurrencesFollowOrKeep` 對 `location` 改成比地點的值（標題、緯度、經度、半徑；nil 與空標題相同，沒有半徑與 0 相同）。令系列舊地點為 Po、寫入的地點為 Pw（標題是寫入的字串，沒有座標、沒有半徑）、場次存檔前後為 Pb、Pa：

- follows：Pb 等於 Po，而且 Pa 等於 Pw。
- keeps：Pb 等於 Pa，而且 Pb 不等於 Po、不等於 Pw。
- 其餘都維持 marker，包括 Pb 等於 Pw（本來就持有寫入的地點）。

場次的 location 字串必須等於它自己的地點標題，否則 marker（沒量過）。既有的「單獨修改過的場次有座標就一律 marker」移除：量到它不是跟著變就是保留，上面兩條已經涵蓋。沒寫 `location` 時，場次地點有任何變化仍算「其他欄位變了」。

`title` 與 `notes` 的判斷不變。

### 第一個時段的規則：由 firstSlot 證明，並在兩次列表中存在

`firstSlotRecordable` 與 `firstSlotIsPlain` 換成一條規則：

- 第一個規則時段由 `DeletedOccurrenceCheck.firstSlot` 證明（第一個場次沒被單獨修改時是它的開始時間；被單獨修改並移動時是它 `/RID=` 的時段）。證明不了就 marker。`firstSlot` 對 detached 的物件、stand-in、開始時間上不只一個場次、移到較早而紀錄的時段對不上的情況本來就回 nil。
- 不再要求 `.stored` 的 baseline。`.stored` 是為了讓計畫中的日期能和儲存的開始時間比較（PR #505 第 5 輪）；只寫這三個欄位的修改不比較日期。
- 該時段在存檔前與存檔後的列表裡都要在：是一般場次，或是單獨修改過的場次。被刪除、或不在列出的範圍內，就 marker。
- 第一個場次是單獨修改過的場次時，和其他場次一樣由 follows／keeps 判斷。
- `covers` 要求證明出的第一個時段與系列顯示的開始時間都落在同一個列出的範圍內。

經 #428（第一個場次被單獨修改、仍在原時段）與 stand-in 的呼叫照舊由 `recordable` 排除，不靠這條規則。

### C2 啟用前先走過紀錄路徑

量測只證明 store 的行為。加上這條排除的那個審查發現（#263 第 2 輪）只留下摘要與 commit 訊息，沒有失敗情境。所以 C2 分三步，任何一步不成立就停：

1. **讀程式碼**（動 C2 的程式之前）：對「第一個場次被單獨移動」的系列，逐項寫下並貼到 #529：
   - `updateEvent` 用來寫入的系列物件怎麼解析出來，`old` 快照取自誰；
   - `postWriteSnapshot` 讀回的 `saved` 是什麼；
   - #236 的 guard（`verifiedEvent`）比的是哪個物件的哪些欄位，顯示的開始時間（被移動後的）在 `saved` 與 undo 時是否一致；
   - `SeriesUpdateUndo.refusal` 的身分檢查（同一組識別碼、有規則、不是 detached）對這個物件成立與否；
   - undo 時的列表把第一個場次列成什麼（時段取自 `/RID=`），`diff` 能否比對；
   - 讀回走的是哪個物件。
2. **實作後的裝置檢查**（文字宣稱 C2 之前）：單一 stdio process、iCloud、名稱含 `#529` 的拋棄式日曆。系列用 `--cli` 建與移動第一場；在同一個 stdio process 裡 update、看 `undo_history`、`undo`；用另一個 `--cli` process 讀回。三種移動（後 1 小時、後 1 天、移到第二場之後）加上「移動且有自己的標題」，每種都要：紀錄是可還原的、undo 成功、讀回的值與識別碼和 update 前相同。「前移 1 小時」另外記錄：`firstSlot` 在紀錄的時段對不上時回 nil（PR #505 特意加的檢查），所以它的預期是「可還原，或 marker」，記下是哪一種；是可還原時照上面的三項檢查，是 marker 時 undo 照 marker 拒絕。**不得為了讓它可還原而放寬 `firstSlot`。**另做兩個拒絕：update 之後用 `--cli` 改另一個場次、改被移動的第一個場次，undo 都要拒絕、什麼都沒寫、紀錄保留。
3. **判定**：第 1 步發現 `old` 取自被移動的場次、或身分檢查不成立；或第 2 步出現身分拒絕、讀回不符、被移動的場次開始時間變了，C2 就維持 marker：還原第一個時段規則的放寬，閉集文字保留「第一個場次沒有單獨修改或刪除過」，結果記在 #529。**規格也要跟著改回**，否則封存進去的會是沒有實作的行為：本 change 的 spec delta 裡 WHEN 的第一個場次那一句改回現行文字，Example「the first occurrence decides the record」中被移動的三列改成 marker，proposal 的「啟用」拿掉 C2 那一條、移到「維持拒絕」，gate 的 8d 不改。其餘部分照常交付。

為什麼不直接啟用：反向寫入是 forward 量的，紀錄與 undo 的比對沒有跑過；審查當時選擇排除，推翻它需要比 store 行為更多的證據。

### 維持拒絕的形狀與理由文字

`restorableShapeNotes` 的理由句照量到的結果改寫：

- 兩種形狀在三個欄位都量過（2026-11-13，iCloud；還沒開始的系列，另有一次已開始的系列）。
- 本來就持有寫入值的場次不在兩種形狀裡，除非寫入的值等於舊值：反向寫入會把它蓋成系列的舊值，放回去需要對那個場次單獨寫一次，undo 不做（#522）。
- 有座標的地點以地點還原（標題、座標、半徑，也就是這個 server 讀得到的值）；行事曆 App 另外存在地點上的東西不讀、不還原、不比對。

「自己的值被取代」「持有舊值卻沒跟」「其他欄位變了」三種判斷不變，仍是 marker。C1、C3b 由 `recordable` 既有的 `throughOwnOccurrence` 與 `viaStandIn` 排除，判斷不變，只有文字改。

### 閉集文字與釘選一起改

`SeriesUpdateUndo.restorableShape` 與 `restorableShapeNotes` 是唯一來源，內容以本 change 的 spec delta 為準（scenario「Restorable whole-series update on iCloud (#263, #529)」的 WHEN）。`Server.swift` 用插值；README（中英文）、CHANGELOG、`docs/UNDO_HISTORY.md`、manifest 兩個條目、spec 各自重述一次。`SeriesUpdateUndoDocsTests` 的片語清單換成新文字的片語，仍然要求每個片語在每份文字裡恰好出現一次。CHANGELOG 改既有的 #263 條目（尚未出版），不另外新增一段重述，否則片語會出現兩次。

C2 若依前一項維持 marker，這裡的第一個場次那一句用舊文字，其餘照新文字。

### release gate 的改寫與在場步驟

`.claude/rules/mcp-binary-version-testing.md` 的 #263 一節：

- 步驟 8：H（本來就持有寫入值）仍預期 marker。H3 記成已量（2026-11-13 經 `--cli`：場次保留自己的 notes），預期改成可還原的紀錄，undo 後該場次仍是自己的 notes。
- 步驟 8d：K（第一場後移 1 小時）、K2（後移 1 天）預期改成可還原的紀錄與成功的 undo，`--cli` 讀回與 update 前相同；加 K3（前移 1 小時：預期照 4.3 量到的那一種，可還原或 marker）、K4（移動且有自己的標題）；另加一項「第一場只改標題、仍在原時段」預期 marker。C2 維持 marker 時，8d 不改。
- 步驟 0 與 9：兩個形狀（改 `start_time`、不設結束的系列）仍是 marker，但拒絕文字帶的是 `restorableShape`，所以兩步引用的文字要換成新閉集的片語；步驟 0 的行為探測另加一個只有新版才有的片語（地點以整個地點比較的那一句），才分得出新版與只有 #263 的版本。步驟 9 另加兩個這一階段維持 marker 的形狀：系列地點有半徑而沒有座標時寫 `location`（工具建得出來才做，建不出來就記成無法執行），以及場次本來就持有寫入的值（與步驟 8 的 H 相同，這裡只引用）。
- 新步驟（座標）：系列地點有座標與半徑，一個場次只改標題，一個場次有自己的有座標地點。session：span `all` 寫 `location`，紀錄可還原；`undo` 成功；`--cli` 讀回每個場次的地點標題、經緯度、半徑與 update 前相同，有自己地點的場次沒變。
- 新步驟（**需要維護者在場**）：維護者在名稱含 `#529` 的拋棄式日曆上建一個系列，並在行事曆 App 裡替它選一個地點。`--cli` 讀 `location` 與 `structured_location`；session 做 span `all` 的 `location` 修改並記下 `undo_history` 是可還原的紀錄還是 marker；可還原時 `--cli` 讀一次、`undo`、`--cli` 再讀一次，維護者在行事曆 App 看該事件的地點。gate 文字寫明：`--cli` 的兩次讀取（update 前與 undo 後）不同，或行事曆 App 顯示地點有東西沒回來，**A 在出版前改回拒絕**（恢復「有座標的地點」這條排除與對應文字），並記在 #529。是 marker 時只記錄結果。

### apply 的起點：#531 合併後的 main

本 change 的 apply 從 #531 合併之後的 `main` 開新分支，或把這個分支 rebase 上去。#531 改了同一個檔案的 slot 比對與 gate 檔；在它之前動手會在同一批函式上衝突。

## Implementation Contract

**行為**

- `update_event`（iCloud、系列自己的 id、span `all`、只傳 `event_id`、`span` 與 `title`／`notes`／`location`）在下列情況留下可還原的紀錄，`undo_history` 列為 `Updated recurring event: <title before the update> (whole series; undo restores its <fields>)`：
  - 寫 `location`，系列舊地點符合「系列地點的可記錄條件」；
  - 每個單獨修改過的場次在每個寫入的欄位是 follows 或 keeps，`location` 以整個地點判斷；
  - 第一個時段符合「第一個時段的規則」（C2 通過前一項的判定時）。
- 其他情況照舊是 marker：`Updated recurring event: <title> (undo not available)`，undo 拒絕、不寫入、丟棄紀錄。
- `undo` 對可還原的紀錄：既有的檢查順序不變；寫入是一次 span `all` 的存檔，寫 update 寫過的欄位，舊地點有座標時加上地點；存檔失敗就 rollback、紀錄保留；讀回比對寫入的欄位（`location` 含地點四個值）、規則與例外，不符時回報已寫入、列出差異、丟棄紀錄。
- `redo`、`keep_later_edits` 對這種紀錄的行為不變。

**資料形狀**

- `SeriesUpdateRecord` 不加欄位：`old` 已有地點四個值，`fields` 仍是 update 寫的欄位；undo 的寫入集合由 `fields` 與 `old` 的地點推得（`location` 在 `fields` 裡且 `old` 有座標時加上 `structured_location`）。
- 地點的比較值：標題（nil 與空字串相同）、緯度、經度、半徑（沒有與 0 相同）。

**失敗模式**

- 判斷不出來的一律 marker（fail closed）：第一個時段證明不了、列表列不出來、場次不在兩種形狀裡、地點不在兩種可記錄的形狀裡。
- undo 時系列和修改留下的狀態不同：拒絕、不寫入、紀錄保留（既有的理由與文字）。
- 讀回不符：照既有的 `readBackError`，差異清單裡地點算在 `location`。

**驗收**

- 純函式測試涵蓋 spec 四個 Example 的每一列，測試檔帶 `spec-example: undo-history-discard / <Example 標題>` 標記。
- 寫入集合的純函式測試與記憶體內事件的套用測試：舊地點有座標時集合是 `location` 加 `structured_location`，套用後事件的地點四個值等於紀錄；wiring 測試釘住 undo arm 用這個集合、只存一次、讀回比對地點，以及第一個時段規則的呼叫順序。既有的 `SeriesUpdateUndoHandlerTests` 用的是未授權的 store，undo 停在存取檢查，跑不到存檔，所以這一段不靠 handler 測試。
- `SeriesUpdateUndoDocsTests`：每個片語在每份文字恰好一次（spec 的那一份在封存之後才會過，照 spec wrapper 的收尾順序）。
- mutation：下面 tasks 列的每一個變異都要讓指名的測試轉紅。
- 裝置：單一 stdio process 的檢查（A 與 C2），結果貼在 #529；出版前的 session MCP gate 是另一件事，照 gate 檔。
- `swift test` 在主機時區與 `TZ=UTC` 都過；`origin/main` 上的測試函式名稱在 HEAD 一個都不少。

**範圍**

- 在內：上面的行為、閉集文字與其重述、gate 檔的 #263 一節、#522 Roadmap 在 Stage 5 下加註移過去的三項。
- 不在內：Non-Goals 列的每一項；#532。

## Risks / Trade-offs

- [undo 這一側沒有跑過；證據是 forward 寫入，每格一個系列] → tasks 裡的單一 stdio process 檢查在文字宣稱之前做；出版前的 session MCP gate 不變。
- [C2 推翻審查時的排除，而該發現沒有留下失敗情境] → 「C2 啟用前先走過紀錄路徑」的三步與退路；退路是原樣的 marker。
- [地點只比四個值；行事曆 App 選的地點沒量過] → 文字寫明還原的範圍；gate 的在場步驟；那一步不過就在出版前把 A 改回拒絕。
- [反向呼叫寫的都是非空字串，nil 沒量過] → 這個 change 不改 nil 的處理；gate 步驟 7、8e 已涵蓋已出貨的形狀，座標的新步驟另外讀回。
- [長駐 store 的列表可能是舊的（#263 的已知限制）] → 新形狀沿用同一套 refresh 請求與 gate 步驟 8、8b；不宣稱列表是最新的。
- [只在 iCloud 量過] → iCloud 的閘門不變；其他來源是 #522 的 Stage 2。
- [與 #531 改同一個檔案] → apply 從 #531 合併後的 `main` 開始。
- [座標用精確相等比較，store 若改寫小數位會讓讀回不符] → 量到的 9 個有座標的系列讀回都相等；不符時的結果是「已寫入、列出差異、丟棄紀錄」，不是靜默通過。

## Open Questions

下面三項是協調者取的預設（#529 的 Decision record），維護者可以改；改了就要回頭改本 change：

- C1 放在 Stage 5（預設），或在這一階段先做第一個場次會跟著變的那一半。
- 把場次自己的值寫回去放在 Stage 5（預設），或拉進這一階段。
- 行事曆 App 選的地點：照設計啟用 A 並加在場的 gate 步驟（預設），或在量到之前維持拒絕。
