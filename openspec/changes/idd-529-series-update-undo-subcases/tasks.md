## 1. 起點與 C2 的紀錄路徑（先讀，不寫 C2 的程式）

- [ ] 1.1 照 design「apply 的起點：#531 合併後的 main」開工：分支建在 PR #531 合併之後的 `main` 上（或把 `idd/529-series-update-undo-subcases` rebase 上去）。行為：工作樹含 #531 對 `SeriesUpdateUndo.swift`、README、CHANGELOG 與 gate 檔的修改，之後的修改不與它衝突。驗證：`git merge-base --is-ancestor <#531 的 merge commit> HEAD` 結束碼 0，`swift build --build-tests` 成功。
- [ ] 1.2 照 design「C2 啟用前先走過紀錄路徑」第 1 步讀程式碼，對「第一個場次被單獨移動」的系列寫下六項：`updateEvent` 的系列物件怎麼解析與 `old` 取自誰、`postWriteSnapshot` 的 `saved`、#236 guard（`verifiedEvent`）比的物件與欄位、`SeriesUpdateUndo.refusal` 的身分檢查、undo 時列表對第一個場次的列法、讀回的物件。行為：每一項有結論與所依據的函式名，並有一句判定（可繼續／C2 維持 marker）。驗證：內容以留言貼在 #529；判定為「維持 marker」時第 4 組整組不做，7.1 用 design「閉集文字與釘選一起改」寫的舊句。

## 2. 地點：純函式（先寫測試、看它失敗、再實作）

- [ ] 2.1 [P] 地點的比較值：新增純函式把快照的地點化成（標題、緯度、經度、半徑），nil 與空標題相同、沒有半徑與 0 相同。行為：兩個地點只差座標或只差半徑時判為不同；nil 標題與空標題、無半徑與 0 判為相同。驗證：`SeriesUpdateUndoTests.testPlaceValuesCompareTitleCoordinatesAndRadius`（先紅後綠）。
- [ ] 2.2 照 design「系列地點的可記錄條件」改 `SeriesUpdateUndo.recordable`：寫 `location` 時只接受兩種舊地點（無地點或標題等於字串且無座標無半徑；標題等於字串且有座標），其餘回 nil。行為：spec Example「the series' own place decides the record when location is written」的四列。驗證：`SeriesUpdateUndoTests.testTheSeriesPlaceDecidesTheRecordWhenLocationIsWritten`，檔內帶 `spec-example: undo-history-discard / the series' own place decides the record when location is written`。
- [ ] 2.3 照 design「單獨修改過的場次：location 比整個地點」改 `SeriesUpdateUndo.occurrencesFollowOrKeep`：`location` 以地點的比較值判斷 follows／keeps，場次的 location 字串須等於它的地點標題，移除「場次有座標就 marker」。行為：spec Example「a location written over a place with coordinates」的六列（地點由值建立，不經 `EKEvent`，因為記憶體內的 EventKit 會把 location 與地點標題綁在一起）。驗證：`SeriesUpdateUndoTests.testALocationOverAPlaceWithCoordinatesFollowsOrKeepsByTheWholePlace`，帶 `spec-example: undo-history-discard / a location written over a place with coordinates`。
- [ ] 2.4 [P] 把 `title`／`notes`／無座標 `location` 的七種場次形狀釘成一張表的測試（判斷不改）。行為：spec Example「an occurrence edited on its own decides the record」的七列，三個欄位各跑一次。驗證：`SeriesUpdateUndoTests.testAnEditedOccurrenceDecidesTheRecordInEveryField`，帶 `spec-example: undo-history-discard / an occurrence edited on its own decides the record`。
- [ ] 2.5 `SeriesUpdateUndo.readBackMismatch` 與 `diff`：`location` 被還原時比對系列地點的四個值，場次的地點差異（含座標、半徑）算進 `edited`。行為：讀回的系列少了座標或半徑時，差異清單含 `location`；場次的座標變了時 `edited` 含該時段。驗證：`SeriesUpdateUndoTests.testTheReadBackComparesThePlaceWhenLocationWasRestored`。

## 3. 地點：EventKit 一側

- [ ] 3.1 照 design「地點還原：location 與 structured_location 在同一次存檔寫回」改 undo 的寫入集合：`fields` 含 `location` 且 `old` 有座標時，`applyRestoring` 的集合加上 `structured_location`，仍只有一次 `eventStore.save`。行為：requirement「Stale and busy protection」的 scenario「Restorable whole-series update on iCloud (#263, #529)」中「the recorded place … is written in that same save, and no other save is made」。驗證：寫入集合抽成純函式（輸入 `fields` 與 `old`，輸出要還原的欄位），`SeriesUpdateUndoTests.testTheUndoWritesThePlaceWithALocationOverCoordinates` 涵蓋有座標、無座標、沒寫 `location` 三種；同一個測試把集合用 `EventSnapshot.applyRestoring` 套到記憶體內的 `EKEvent`，斷言 `structuredLocation` 的標題、座標、半徑等於紀錄；`SeriesUpdateUndoWiringTests` 釘住 undo arm 把這個集合交給 `applyRestoring`，且 arm 內只有一個 `eventStore.save(`。（`SeriesUpdateUndoHandlerTests` 的 store 未授權，undo 停在存取檢查，驗不到存檔。）
- [ ] 3.2 record 端把系列地點交給新的 `recordable` 條件（`seriesUpdatePlan` 傳地點的比較值與 location 字串，不再傳 `placeHasCoordinates`）。行為：有座標的系列地點被 `location` 覆寫時留下可還原的紀錄；標題與字串不同的地點仍是 marker。驗證：`SeriesUpdateUndoWiringTests` 的呼叫引數釘選各恰好符合一次；`SeriesUpdateUndoCaptureTests` 既有案例照過。

## 4. 第一個時段（C2；1.2 判定可繼續時才做）

- [ ] 4.1 照 design「第一個時段的規則：由 firstSlot 證明，並在兩次列表中存在」新增純函式取代 `firstSlotRecordable`／`firstSlotIsPlain`：時段非 nil、在存檔前後的列表裡是一般場次或單獨修改過的場次；`covers` 同時要求證明出的時段與顯示的開始時間在同一個範圍內。行為：spec Example「the first occurrence decides the record」的八列（#428 與 stand-in 兩列由 `recordable` 判定）。驗證：`SeriesUpdateUndoTests.testTheFirstOccurrenceDecidesTheRecord`，帶 `spec-example: undo-history-discard / the first occurrence decides the record`；既有的 `testTheFirstSlotMustBeAPlainListedOccurrence` 改寫成新規則（函式名稱保留或在 9.2 的清單說明更名）。
- [ ] 4.2 `seriesUpdatePlan` 與 `seriesUpdateRecord` 改用 4.1 的規則，被單獨移動的第一個場次交給 `occurrencesFollowOrKeep`。行為：第一個場次被單獨移動、其餘條件符合的系列留下可還原的紀錄；時段證明不了時是 marker。驗證：`SeriesUpdateUndoWiringTests` 釘住 plan 與 record 兩處的呼叫與順序（各恰好一次）。
- [ ] 4.3 照 design「C2 啟用前先走過紀錄路徑」第 2、3 步做裝置檢查並判定：單一 stdio process、iCloud、名稱含 `#529` 的拋棄式日曆，三種移動（後 1 小時、後 1 天、移到第二場之後）加「移動且有自己的標題」，以及兩個拒絕（update 後用 `--cli` 改另一個場次、改被移動的第一個場次）；「前移 1 小時」另外記錄它是可還原還是 marker，不得為它放寬 `DeletedOccurrenceCheck.firstSlot`。行為：三種移動與有自己標題的那一種，紀錄可還原、undo 成功、另一個 `--cli` process 讀回的值與識別碼和 update 前相同；兩個拒絕都不寫入、紀錄保留。驗證：逐項結果與判定貼在 #529；任何一項不成立就還原 4.1、4.2，7.1 用舊句，**並把 spec delta 的第一個場次那一句與 Example「the first occurrence decides the record」被移動的三列、proposal 的 C2 條目、gate 的 8d 改回 marker 的寫法**，在 #529 記下原因。結束後依 id 刪除拋棄式日曆，隔一分鐘以上數兩次，名稱含 `#529` 的為 0。

## 5. 裝置檢查：有座標的地點

- [ ] 5.1 單一 stdio process、iCloud、名稱含 `#529` 的拋棄式日曆：系列地點有座標與半徑，一個場次只改標題，一個場次有自己的有座標地點；update 寫 `location`、看 `undo_history`、`undo`，另一個 `--cli` process 讀回。行為：紀錄可還原；undo 成功；每個場次的地點標題、經緯度、半徑與 update 前相同，有自己地點的場次沒變。另做一個拒絕：update 後用 `--cli` 改一個場次的地點，undo 不寫入、紀錄保留。驗證：結果貼在 #529；讀回不符就停下，A 不啟用（2.2 回到舊條件），並在 #529 記下差異。結束後清理同 4.3。

## 6. Mutation

- [ ] 6.1 對新判斷逐一做變異，每個都要讓指名的測試轉紅，結果列表貼在 #529（存活的變異要補測試或說明為何等價）：(a) 地點比較只比標題 → 2.1、2.3 的測試；(b) 比較值漏掉半徑 → 2.1；(c) 接受「有半徑沒座標」的系列地點 → 2.2；(d) 接受標題與字串不同的系列地點 → 2.2；(e) 把本來就持有寫入地點的場次判成 keeps → 2.3；(f) 場次 location 字串與地點標題不同時仍接受 → 2.3；(g) 讀回不比地點 → 2.5；(h) undo 不寫 `structured_location` → 3.1 的 handler 測試；(i) 第一個時段只查存檔前的列表 → 4.1；(j) 接受 nil 的第一個時段 → 4.1；(k) `covers` 不看證明出的時段 → 4.1。行為：每個新增的條件都有測試擋住它被拿掉。驗證：每個變異各跑一次 `swift test --filter SeriesUpdateUndo`，記錄轉紅的測試名稱。

## 7. 閉集文字與釘選

- [ ] 7.1 照 design「閉集文字與釘選一起改」與「維持拒絕的形狀與理由文字」改 `SeriesUpdateUndo.restorableShape` 與 `restorableShapeNotes`，內容等於 spec delta 該 scenario WHEN 裡的兩段（C2 維持 marker 時，第一個場次那一句用現行文字）。行為：marker 的拒絕文字、`undo` 與 `update_event` 的描述（`Server.swift` 插值）說的是新的閉集。驗證：`SeriesUpdateUndoDocsTests.testTheSwiftConstantsHoldEveryPhraseOnce` 以新的片語清單通過；`ManifestParityTests` 通過。
- [ ] 7.2 [P] `README.md` 的 #263 段落重述新閉集與理由句。行為：英文讀者看到的可還原形狀與常數一致。驗證：`SeriesUpdateUndoDocsTests.testEveryEnglishTextStatesTheListOnce` 對 `README.md` 通過。
- [ ] 7.3 [P] `README_zh-TW.md` 的對應段落用中文重述，中文片語清單同步更新。行為：中文讀者看到的形狀與英文一致。驗證：`SeriesUpdateUndoDocsTests` 的中文測試通過。
- [ ] 7.4 [P] `CHANGELOG.md`：改既有的 #263 條目（尚未出版），加上 #529 啟用的兩種形狀與維持拒絕的理由，不另加一段重述。行為：每個片語在 CHANGELOG 仍恰好出現一次。驗證：`testEveryEnglishTextStatesTheListOnce` 對 `CHANGELOG.md` 通過。
- [ ] 7.5 [P] `docs/UNDO_HISTORY.md` 的 #263 段落重述新閉集，並寫明「還原」對地點只涵蓋標題、座標、半徑。行為：文件與行為一致。驗證：`testEveryEnglishTextStatesTheListOnce` 對 `docs/UNDO_HISTORY.md` 通過。
- [ ] 7.6 [P] `mcpb/manifest.json` 的 `undo` 與 `update_event` 兩個條目重述新閉集。行為：Claude Desktop 看到的描述與 `Server.swift` 一致。驗證：`SeriesUpdateUndoDocsTests` 的 manifest 測試與 `ManifestParityTests` 通過。
- [ ] 7.7 `SeriesUpdateUndoDocsTests` 的英文與中文片語清單換成新文字的片語（移除不再出現的、加入新的：第一個場次那一句、地點以整個地點比較、還原為地點的那一句、量過的那一句、放回去需要單一場次寫入的那一句）。行為：之後任何一份文字漂移，測試就轉紅。驗證：把任一份文字的一個新片語刪掉，對應測試轉紅；還原後全綠。

## 8. release gate 與追蹤

- [ ] 8.1 照 design「release gate 的改寫與在場步驟」改 `.claude/rules/mcp-binary-version-testing.md` 的 #263 一節：步驟 8（H3 記成已量、預期可還原）、8d（K、K2 預期可還原並 undo 成功，加 K3、K4 與「第一場只改標題、仍在原時段」預期 marker；C2 維持 marker 時不改）；步驟 0 與 9 引用的拒絕文字換成新閉集的片語，步驟 0 另加一個只有新版才有的片語，步驟 9 加上「系列地點有半徑沒座標」的 marker；新增座標步驟；新增需要維護者在場的步驟，並寫明那一步顯示地點有東西沒回來時 A 在出版前改回拒絕。行為：出版前的檢查清單與新行為一致，且每一步寫了預期結果與不符時的處置。驗證：對照 design 該節逐項核對；`grep -c '需要維護者在場'` 在該節至少 1。
- [ ] 8.2 在 #522 的 Roadmap 於 Stage 5 下加註從本階段移過去的三項（B(i) 的寫回、C1、C3b），附 #529 Diagnosis 的連結。行為：追蹤 issue 上看得到這三項沒有消失。驗證：`gh issue view 522` 的 Roadmap 含這三項。

## 9. 收尾

- [ ] 9.1 全套測試。行為：既有行為沒有退化。驗證：`swift build --build-tests` 後 `swift test --skip-build` 在主機時區與 `TZ=UTC` 都是 0 failures。
- [ ] 9.2 被刪除的測試檢查。行為：測試總數變多不代表沒有測試被刪。驗證：`origin/main` 上每個測試函式名稱在 HEAD 都還在；更名的逐一列出舊名與新名。
- [ ] 9.3 封存後核對 spec：requirement「Stale and busy protection」的 scenario 文字與常數一致。行為：`openspec/specs/undo-history-discard/spec.md` 帶新的閉集，且每個片語恰好一次。驗證：封存（spec wrapper 的收尾步驟）之後 `testEveryEnglishTextStatesTheListOnce` 對 spec 通過；`spectra validate` 通過。
