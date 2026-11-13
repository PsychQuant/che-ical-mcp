## Why

`undo` 目前只還原一種循環事件修改：iCloud 上經系列自己的 id、span `all`、只寫 `title`、`notes` 或 `location` 的 `update_event`（#263，PR #519）。這個形狀裡還有三類情況被排除，只留下 marker，`undo` 拒絕並丟棄紀錄（#529，#522 的 Stage 1）：

- **A**：`location` 寫在有座標的地點上。
- **B**：單獨修改過的場次不在兩種已量形狀（follows、keeps）裡。
- **C**：第一個場次被單獨修改或刪除過。

這些排除都是 #263 審查時沒有量測就先取的保守選擇（判斷不出來就不還原）。Diagnosis（#529）在 2026-11-13 用 iCloud 的拋棄式日曆補了量測（40 個系列，`ba98641` 的 release build 經 `--cli`），結果足以把其中兩類打開，其餘的拒絕理由也從「沒量過」變成「量到會丟資料」或「這一階段沒有對應的寫入路徑」。

維護者在 #522 已決定七種形狀都要支援，並接受了分階段的順序。本 change 是第一階段。#529 的「Decision record (coordinator defaults, 2026-11-13)」留言記錄了四個由協調者依該順序取的預設，本 change 照那四項寫；它們不是維護者的回答，維護者改了其中一項，本 change 的對應部分就要跟著改。

## What Changes

**啟用（undo 會還原）**

- **A：`location` 寫在有座標的系列地點上。** 紀錄已經有修改前的地點（標題、緯度、經度、半徑）。undo 在同一次存檔還原 `location` 與 `structured_location`，讀回時比對地點的這四個值。「還原」只涵蓋這四個值，每一份文字都要這樣寫。
- **A：單獨修改過的場次，`location` 改成比整個地點。** 量到 store 比的是整個地點而不是 location 字串：場次的地點只要和系列的不同（即使只差座標）就保留。所以「follows」是場次原本持有系列的整個舊地點、之後持有寫入的地點；「keeps」是它的地點和兩者都不同且沒變。「單獨修改過的場次有座標就一律 marker」這條移除。
- **C2：第一個場次被單獨修改並移離原本的時段。** 量到這種系列經系列 id 的整串寫入與一般系列相同（6 個系列，移後 1 小時、後 1 天、前 1 小時、移到第二場之後；另含第一場自己有標題的兩格）。這是 store 的行為；哪些移動會留下可還原的紀錄，取決於第一個時段能不能被證明（往前移的那一種可能證明不了，那就仍是 marker）。條件改成：第一個規則時段能由 `DeletedOccurrenceCheck.firstSlot` 證明（經該場次的 `/RID=`），系列物件不是 detached、不是 stand-in，該時段在存檔前後的列表裡都在（一般場次或單獨修改過的場次皆可）；第一個場次被單獨修改時，和其他單獨修改過的場次一樣用 follows／keeps 判斷。**啟用的前提是先走過紀錄路徑**（tasks 第 1 組）；走過之後有任何一步不成立，C2 維持 marker，本 change 只交付其餘部分，而且這一條、spec delta 裡第一個場次那一句與對應的 Example 都要改回「第一個場次沒有單獨修改或刪除過」再封存。

**只改文字**

- **B 的 follows 與 keeps**：從「依量到的結果推到三個欄位」改成「三個欄位都量過」。#263 release gate 步驟 8 的 H3 記成已量（場次保留自己的 notes）。

**維持拒絕（理由改寫成量到的結果，並寫明移到 #522 的 Stage 5）**

- **B(i)：場次本來就持有寫入的值。** 量到整串的反向寫入會把它蓋成系列的舊值（每欄 2 次），整串存檔無法避免。要還原得對那一個場次再存一次，這一階段不做單一場次的寫入。
- **B 的其餘三種**（自己的值被寫入取代、持有舊值卻沒跟、沒寫的欄位變了）：經系列物件寫入的 32 個系列裡沒有出現過，維持拒絕。出現就表示 store 做了沒量過的事。
- **C1：第一個場次被單獨修改、仍在原本的時段**（經系列 id 會走 #428，寫入物件是那個場次）。store 在該場次跟著變時兩個方向都還原，但 undo 這一側沒有這條路徑。
- **C3b：第一個場次被刪、下一個場次被單獨修改**（forward 會起新系列、id 換新）。值能還原，id 回不來。
- **系列地點的名稱和它的 location 字串不同**：用工具建不出來，沒量過。

**沒有東西可改**

- **C3：第一個場次被刪、下一個場次沒改。** `update_event` span `all` 本身被 #326 拒絕，不會有紀錄。

**文字與 gate**

- `SeriesUpdateUndo.restorableShape` 與 `restorableShapeNotes` 改寫，每一份重述它們的文字一起改（README 中英文、CHANGELOG、`docs/UNDO_HISTORY.md`、`undo-history-discard` spec、manifest 的兩個條目、`undo` 與 `update_event` 的描述），`SeriesUpdateUndoDocsTests` 的釘選跟著換。
- #263 release gate 一節：步驟 8（H3 記成已量）、8d（第一場被移動的系列改成預期可還原並 undo 成功）、9 改寫；新增有座標地點的步驟；新增一步**需要維護者在場**的檢查（在拋棄式系列上用行事曆 App 選一個地點，`--cli` 讀更新前、更新後與 undo 之後）。gate 文字寫明：那一步若顯示地點有東西沒回來，A 在出版前改回拒絕。

## Non-Goals (optional)

- 不做任何單一場次（span `this`）的寫入，所以不還原 B(i)，也不還原 C1 裡第一個場次自己的值。#522 把 span `this` 放在 Stage 5，並要求先重現 #262。
- 不替 undo 加上經 #428 或 stand-in（#326）的寫入路徑；C1、C3b 留給 Stage 5。
- 不擴大到 iCloud 以外的來源（Stage 2）、列不完的系列（Stage 3）、其他欄位（Stage 4）。
- 不改 `update_event` 的行為；這個 change 只改「哪些修改留下可還原的紀錄」與 undo 怎麼還原。
- 不處理 #532（已單獨修改過的場次用系列 id 加日期找不到），那是另一張 issue。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `undo-history-discard`: requirement「Stale and busy protection」的 scenario「Restorable whole-series update on iCloud (#263)」改寫：可還原的形狀納入有座標的系列地點與被單獨移動的第一個場次，還原與讀回涵蓋地點的標題、座標與半徑；維持拒絕的形狀寫明量到的理由。

## Impact

- Affected specs: `undo-history-discard`
- Affected code:
  - `Sources/CheICalMCP/EventKit/SeriesUpdateUndo.swift`（`recordable`、`occurrencesFollowOrKeep`、`placeIsLocation`、`firstSlotRecordable`、`firstSlotIsPlain`、`covers`、`readBackMismatch`、`restorableShape`、`restorableShapeNotes`）
  - `Sources/CheICalMCP/EventKit/EventKitManager+SeriesUpdateUndo.swift`（plan、record、undo 的寫入與讀回）
  - `Sources/CheICalMCP/Server.swift`（描述由常數插入，不改結構）、`mcpb/manifest.json`
  - Tests：`SeriesUpdateUndoTests`、`SeriesUpdateUndoCaptureTests`、`SeriesUpdateUndoHandlerTests`、`SeriesUpdateUndoWiringTests`、`SeriesUpdateUndoDocsTests`
  - 文件：`README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`docs/UNDO_HISTORY.md`、`.claude/rules/mcp-binary-version-testing.md`
- 已知衝突：PR #531（#527）也改 `SeriesUpdateUndo.swift`、README、CHANGELOG 與 gate 檔，預計先合併。**本 change 的 apply 要在 #531 合併之後、從新的 `main` 開始。**
- 證據的界線：量測全部是 forward `update_event`（iCloud，每格一個系列），沒有跑過任何一次 `undo`。undo 這一側要靠 tasks 裡的單一 stdio process 檢查與出版前的 session MCP gate 證明。
