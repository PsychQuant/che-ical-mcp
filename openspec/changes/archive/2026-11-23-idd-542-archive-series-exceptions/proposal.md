## Why

change `restore-series-exceptions-on-delete-undo`（#285、#319、#321）在 v1.21.0 起的每個版本都出貨了，卻一直沒有封存，所以 base spec `undo-history-discard` 的「Stale and busy protection」仍寫著 #285 之前的整個系列刪除 undo（只依規則重建，之後 undo 單一場次的刪除會再寫一次而且不提醒），也沒有視窗、例外還原、「對不上就什麼都不套用」、slot guard 這些情境（#542）。

那個 change 的 delta 是對整個 requirement 的 MODIFIED，從 2026-10-12 的 base 分出來。之後 base 又加了 #424 那一句、#265、#269、#263、#273、#287 的情境。照原樣封存會把它們拿掉或改回舊文字（在 `openspec/` 的拋棄式複本上跑過 `spectra archive`，再與 `origin/main` 比對）。

## What Changes

- 本 change 的 delta 是合併後的「Stale and busy protection」：以目前的 base 為底，逐個情境合併：
  - base 較新、保留 base：requirement 段落、#265、#269、#263、#273、兩個 #287 情境、「Update of a recurring event」、「Update or move of a one-off event that repeats at undo time」、「Batch member cannot be restored」。
  - 取 delta：「Delete of one occurrence (#244)」（slot guard、#323）。
  - #285 之前的「Delete of a whole series (#244)」換成 delta 的「…that holds no exceptions (#244, #285)」與其餘八個 #285／#319 情境、三個 #321 情境。
  - 「Batch undo fails part-way」：base 的寫法加上 delta 對系列成員永久錯誤的子句。base 寫的「no batch member's write throws such an error today」不對：series restore 的補償刪除失敗時，`SeriesExceptionsUndo.restoreFailure` 丟 `UnrecoverableUndoError`。
  - 一處依程式更正：例外還原時，編輯過的場次的規則時段取自 event identifier 或 external identifier 的 `/RID=`，都沒有時用 occurrence date（#539 那個 requirement 的讀法），不只是「its identifier」。
- `restore-series-exceptions-on-delete-undo` 以 `--skip-specs` 封存，它的 delta 保留原樣、沒有套用；tasks 8.3（#324）與 10.4（#579）維持未完成，寫明跑過什麼、還欠什麼、移到哪裡。
- 新增 `SeriesExceptionsSpecDocsTests`，釘住合併後的情境清單與順序、拿掉的舊情境、兩邊各自帶來的子句，以及封存後的兩個未完成 task。

## Non-Goals

- 不改任何程式、README、CHANGELOG、manifest 或工具描述：出貨的行為沒有變，只有規格補上。
- 不跑 #319／#321 的 release gate（要在重啟後的 session MCP 上跑，移至 #579），也不跑 #324 的裝置驗證。
- `openspec/changes/` 下其他八個沒有封存的 change 另開 #580，不在這裡處理。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `undo-history-discard`：requirement「Stale and busy protection」補上已出貨的整個系列刪除 undo 情境（#285、#319、#321），保留之後加入的情境。

## Impact

- `openspec/specs/undo-history-discard/spec.md`（只有這一個 requirement）、`openspec/changes/archive/`、`Tests/CheICalMCPTests/SeriesExceptionsSpecDocsTests.swift`。
- 讀這份 spec 的另外三個文件測試（`UndoPostStateWindowDocsTests`、`SeriesUpdateUndoDocsTests`、`UndoForecastDocsTests`）的釘選照舊。
