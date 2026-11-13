## Problem

PR #545（#532、#534、#535）的第一輪 verify 回了 6 個 MEDIUM、16 個 LOW、15 個 INFO，其中一個擋 merge：

- **沒有時區的非全天系列（擋 merge）**：這種系列裡被單獨修改過的場次，`/RID=` 是原本的牆上時間讀成 UTC（#539），不是那個時刻。`EditedOccurrenceAddress.matches` 把它當成時刻讀，呼叫端又把沒有時區補成主機時區，所以在不是 UTC 的主機上，用系列識別碼加一個系列沒有場次的日子，會被答成別天那個場次的拒絕（`main` 回找不到），印出的「原本的日期」也可能差一天。
- **列出範圍**：系列的列出從第一場起算四年，開始超過約五年的每週系列裡，被移離要求那一天的場次列不到，答案仍是找不到，而三個工具說明寫的是會給出它的識別碼。
- **span `future` 的訊息**：沒有說經被往後移的場次的識別碼做 span `future` 時，寫入或刪除從原本的日期開始，會碰到要求那一天之前的場次。
- **搬移列的日期**：訊息印的是系列時區的那一天，而照訊息再打一次時，`occurrence_dates` 是用場次自己的時區讀的。
- **排除日的衝突訊息**：場次是被移到排除日上時，既有的「its exclusion set differs from the request」不是事實。
- **寫進訊息的識別碼**：允許字元清單之外沒有形狀限制，經系列列出找到、前綴不是呼叫端識別碼的識別碼也會被寫出來；另有一個擋不了任何東西的 sanitizer 條件被當成閘門。
- 其餘是文字、規格用詞與測試（handler 測試只證明原樣傳遞、`contains()` 釘選、`XCTSkip`）。

## Root Cause

- `UndoPostState.ruleSlot` 對非全天系列直接回 `/RID=` 的時刻；呼叫點傳 `timeZone ?? .current`，沒有時區這件事到不了純函式。
- `seriesReadings` 用的是 `seriesOccurrences` 的預設範圍（`seriesScanWindow`：第一場起 1460 天）。
- 訊息的文字在量測之前寫定；`Reading` 沒有帶場次自己的時區。
- `echoed` 只檢查字元與長度。

## Proposed Solution

- `EditedOccurrenceAddress.Request` 帶著系列的時區原樣進來（`seriesZone: TimeZone?`）。非全天而沒有時區的系列不讀時段（`readsSlots`）：只用場次開始的那一天比對，不回 `originallyThatDay`、不印原本的日期；`delete_event` span `future` 的訊息仍說切點在原本的日期，並說明這個 server 讀不到那個日期。真正的讀法留給 #539。
- 系列改成以要求的那一天為中心、前後各 366 天列出（`listingRange`），不再從第一場起算；`SeriesListingKey` 含範圍，別的範圍留下的列出不會被拿來用。
- span `future`：場次在要求的那一天開始、原本的日期較早時，刪除的訊息說明兩個日期之間的場次也會被刪，更新的訊息說明寫入從原本的日期開始（iCloud 量過標題）。更新訊息的另一條路以 #416 的結尾與限制收尾，三段都讀同一組常數。
- 搬移列的日期用場次自己的時區印（全天或沒有時區的用主機時區），與系列時區的那一天不同時註明。
- 排除檢查改回三種結果（`Presence`）：查找解析到的維持原訊息，被單獨修改過的場次在那一天開始的用自己的訊息；只讀當天、只看開始時間，不讀時段。
- 識別碼只有在剛好是呼叫帶的系列識別碼、接 `/RID=` 與 ASCII 數字時才寫進訊息；拿掉 sanitizer 條件。
- 工具說明、manifest 摘要、兩份 README、CHANGELOG、release gate 寫出拒絕何時適用與上述限制；測試照 R5、R12 到 R15 補強。

## Non-Goals

- 沒有時區的系列的時段讀法（#539）。
- 經系列識別碼找到被修改的場次並寫入。
- 第一場被刪掉、代表場次被改成另一種全天狀態時的 `seriesIsAllDay`（寫成沒量過的限制，不修）。
- Google 與 Exchange 的量測；出版的 binary。
- `delete_events_batch`：它的 `event_ids` 不接受日期，這條路沒有同樣的問題。

## Success Criteria

- 純函式測試：沒有時區的每週系列，週四 20:00，`/RID=` 是那個牆上時間讀成 UTC，場次現在在週六開始，主機 Asia/Taipei，要求週五：沒有符合的。拿掉 `readsSlots` 的判斷時這個測試失敗。
- 列出範圍不含被移動場次時答案是找不到；範圍是要求那一天前後各 366 天，與系列第一場無關。
- 每一個新分支（時區、範圍、自己的時區、衝突訊息、識別碼形狀）各有一個 mutation 讓測試失敗。
- 裝置（iCloud、簽章過的 release build、`--cli`）：沒有時區的系列、開始六年多的系列、被往後移的場次、有自己時區的場次四格，以及更新、刪除、搬移、#534 重試各一格回歸。
- 整套測試在主機時區、`TZ=UTC`、`TZ=America/Los_Angeles` 都是 0 失敗，沒有測試被移除。

## Impact

- Affected specs: `edited-occurrence-addressing`（修改 5 個 requirement）、`recurrence-excluded-dates`（修改 1 個 requirement）。
- Affected code:
  - `Sources/CheICalMCP/EventKit/EditedOccurrenceAddress.swift`
  - `Sources/CheICalMCP/EventKit/EventKitManager.swift`
  - `Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift`
  - `Sources/CheICalMCP/EventKit/DetachedOccurrenceSpan.swift`
  - `Sources/CheICalMCP/Server.swift`
  - `mcpb/manifest.json`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressTests.swift`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressHandlerTests.swift`
  - `Tests/CheICalMCPTests/EditedOccurrenceAddressWiringTests.swift`
  - `Tests/CheICalMCPTests/ManifestParityTests.swift`
  - `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`.claude/rules/mcp-binary-version-testing.md`
