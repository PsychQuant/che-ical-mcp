## Context

`cleanup_completed_reminders` 透過 `EventKitManager.deleteRemindersBatch` 刪提醒。當 `eventStore.remove(reminder, commit: true)` throw，catch block 直接把 `error.localizedDescription` 寫進 `failures[].error` 回給 MCP client（`EventKitManager.swift:1377`）。

#21 Round 2 的 Security teammate 已經逐一驗證目前 macOS 的 EventKit `NSError` 字面值不會夾帶 reminder content — 都是類別型訊息如 `"The operation couldn't be completed. (EKErrorDomain error 3.)"`。但這個結論建立在 Apple 內部實作細節上，macOS 任何版本都可能改。#32 的目標是拔掉這個隱式依賴：讓 `failures[].error` 的值域不再由 Apple 決定，而由我們的 code 決定。

#31 剛落地的 `EventKitManaging` protocol + `FakeEventKitManager` harness 正好提供測試載具 — 可以腳本化各種 `NSError(domain:code:userInfo:)` throw 給 handler，斷言出去的 `failures[].error` 是我們定義的穩定 code、而不是 Apple 原字串。#32 是 harness 的第一個正式消費者。

現有相關 code：
- `EventKitManager.swift:1355-1385` — `deleteRemindersBatch` 主迴圈（target）
- `EventKitManager.swift:1780` — `BatchDeleteResult.failures` 型別
- `Tests/CheICalMCPTests/FakeEventKitManager.swift` — `scriptDeleteError(_:)` 和 `scriptDeleteResult(_:)`（已能直接用）
- `Tests/CheICalMCPTests/CleanupHandlerTests.swift:testBindingModeFailureSurfacesInResponse` — 已驗證 fake 的 `BatchDeleteResult.failures` 原樣反映在 response（我們在上面加新 assertion 即可）

## Goals / Non-Goals

**Goals:**

- `failures[].error` 的值在 `deleteRemindersBatch` catch block 輸出後，只能是我們 code 產的穩定字串；不可能透傳 Apple 任意 localized 訊息
- 純函式 sanitizer 可獨立單元測試（輸入 `NSError` / Swift `Error` → 輸出 code）
- Integration test（via `FakeEventKitManager`）驗證 handler→manager→sanitizer→response 整條鏈
- Operator 本地除錯不退化：raw `localizedDescription` 仍寫 stderr，只是不回 client
- 不改 MCP wire format — `failures[].error` 仍是 string，field 名不變

**Non-Goals:**

- 不處理其他 8 個 `.localizedDescription` 外洩點（follow-up issue 管）
- 不引入 `{code, message}` object 或新 response 欄位（避免 breaking）
- 不維護人類可讀的 Apple error code 對照表（drift 風險 > 價值）
- 不改 stderr 日誌格式

## Decisions

### D1. 純函式 sanitizer，不是 method on error

**Decision**: `EventKitErrorSanitizer` 是 `enum` 帶 `static func sanitize(_ error: Error) -> SanitizedError`，`SanitizedError` 是 `struct { let code: String; let rawLog: String }`。

**Rationale**:
- 無狀態 / 無依賴 → 測試只要組 `NSError` 就能斷言
- 不污染 `Error` protocol extension（避免全專案其他 catch 誤用）
- Swift `enum` 當 namespace 是專案既有慣例

**Rejected**:
- `extension Error { var sanitized: SanitizedError }` — 太容易被誤呼叫、scope 外擴
- Class / protocol — 無狀態不需要多型，YAGNI

### D2. Code 格式：`eventkit_error_<N>` / `error_<domain>_<N>` / `error_unknown`

**Decision**:
- `EKErrorDomain` (`"EKErrorDomain"`) 的 `NSError` → `"eventkit_error_\(nsError.code)"`
- 其他 `NSError` → `"error_\(slug(domain))_\(nsError.code)"`，`slug` = 取 domain 最後一段（`.` 切後最後一項）、保留字母數字、其他轉 `_`、小寫
- 非 `NSError` Swift `Error` → `"error_unknown"`

**Rationale**:
- 全域確定：輸入 NSError 時 code 可逆對應 `(domain, code)`，外部 operator 仍能 decode
- 不試圖翻譯成英文句子 → 避免翻譯表 drift
- `eventkit_error_3` 比 `eventkit_error_eventNotFound` 穩 — Apple 可能重編號碼，但「我們不猜命名」這條更重要
- `slug` 規則用 `ASCII alphanumeric` 做白名單，保證 output 沒有任何可能來自 user content 的字元（NSError.domain 理論上由 framework 產，但白名單額外保險）

**Rejected**:
- 只用 `"error"` — 太模糊，operator debug 從 response 讀不出錯誤類別
- 包 `NSError.userInfo` — `userInfo` 可能含 `NSLocalizedFailureReasonErrorKey` 之類任意字串，正是 #32 要避免的來源

### D3. Raw log 寫 stderr，不回 response

**Decision**: `deleteRemindersBatch` catch block 先呼叫 sanitizer 拿 `(code, rawLog)`，然後：
- `failures.append((item.identifier, sanitized.code))`
- `FileHandle.standardError.write(Data("deleteRemindersBatch(\(id)) failed: \(sanitized.rawLog)\n".utf8))`

**Rationale**:
- Operator 仍能完整除錯（既有 stderr 日誌習慣延續）
- Client 看到的 `failures[].error` 完全由 sanitizer 決定
- 兩條路徑分離 → trusted surface（stderr）和 untrusted surface（response）明確分邊

**Rejected**:
- 只寫 stderr 不包 sanitizer → client 端 `failures[].error` 會變 `nil` / 空字串，破壞既有 schema
- Response 加 `raw_error` trusted 欄位 → 當下 client 沒有 consumer，YAGNI，且擴大 response shape

### D4. 範圍限縮到 `deleteRemindersBatch` 單一 catch block

**Decision**: 只改 `EventKitManager.swift:1377`。其他 8 處 `.localizedDescription` 外洩由 follow-up issue 處理。

**Rationale**:
- 呼應 #31 narrow scope 設計 — 先把 harness ↔ sanitizer ↔ catch-path 這條鏈打通並驗證
- `cleanup_completed_reminders` 是 #32 issue body 明確指名的 consumer，且 #31 harness 已覆蓋這個 handler
- 其他 handler 各自有不同 call pattern（非 actor / 不同 error 來源 / 不同 response shape），強行套用會讓 proposal 同時改 9 處、測試覆蓋率不對稱
- Follow-up issue 的 template 由 #32 建立後，後續一份一份掃很容易

**Rejected**:
- 同時改 9 處 — 超過 SDD 合理單位（>15 tasks），且難以在單一 PR 可靠驗證

### D5. `BatchDeleteResult.failures` tuple 不動

**Decision**: `failures: [(String, String)]`（identifier, error string）型別保持；只在 docstring 加一條「第二個元素必須是 sanitizer 產的 stable code」。

**Rationale**:
- 不做型別 breaking change（`SanitizedError` 只活在 sanitizer 內部邊界）
- `BatchDeleteResult` 由 EventKitManaging 協定回傳 → 改型別會觸發協定更新 + fake 更新 + 三處 call site 更新，擴大範圍違反 D4
- Docstring 就夠 — 加上 sanitizer 成為唯一產 failures.error 的路徑（catch block only），語言層不需要強制

**Rejected**:
- 改成 `failures: [(String, SanitizedError)]` — 觸發連鎖型別變更，且協定 `EventKitManaging` 會洩漏內部型別到 test 邊界

## Risks / Trade-offs

- **Risk**: Sanitizer 錯放 `userInfo` 某些 key 進 output → 等於把洩漏從 `localizedDescription` 搬到 sanitizer 自己。**Mitigation**: D2 white-list，sanitizer 只讀 `domain`（framework 產）和 `code`（整數），完全不碰 `userInfo`；單元測試覆蓋 userInfo 滿是 reminder title 的 NSError，斷言 output 不含該 title。
- **Risk**: operator 失去 debug 能力。**Mitigation**: D3 stderr 保留 raw；既有 operator 除錯習慣是看 stderr（`main.swift:38,51` 已是此 pattern），不退化。
- **Trade-off**: `eventkit_error_3` 不如 `"event not found"` 易讀 → 犧牲 client 端 UX 換長期安全。**Accepted**: 與 #32 issue body 方向一致，且 client 可讀 `(domain, code)` 對應 Apple 文件（EKError.Code enum）自行映射。
- **Trade-off**: 只改 1 處，剩 8 處仍洩漏風險。**Accepted**: D4 narrow scope；follow-up 必建立，有 #31 open #33-#36 的前例。
- **Risk**: 未來 Apple 實際改 `EKErrorDomain` 為 `"com.apple.eventkit"` 字面值 → sanitizer 必須更新 domain match。**Mitigation**: Sanitizer 定義 `private static let eventKitDomain = EKErrorDomain`（用 Apple 常數，不 hardcode 字面值），Apple 若改常數我們自動跟上。
