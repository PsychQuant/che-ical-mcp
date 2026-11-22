## Why

PR #565 的第二輪審查指出，變更紀錄、現行規格及裝置驗證紀錄需要明確區分新增的拒絕、繼承自 main 的限制，以及舊版實測結果。

## What Changes

- 記錄 00:00 UTC 原日時段的相容性變更，以及議題 #543 仍追蹤的日期比對問題。
- 原日無法確定時，拒絕訊息提供比對所用的開始日期與省略 `occurrence_date` 的做法。
- 精確驗證未改成全天、沒有時區的計時場次，並釐清 Apia 案例所驗證的路徑。
- 本規格取代 `idd-543-allday-occurrence-date` 與 `idd-543-fix1` 對系列全天旗標和原日的舊規格。洛杉磯案例的 2026-12-28 會因原日無法確定而拒絕。

## Non-Goals

本輪限於驗證與文字，日期比對及寫入路徑沿用上一輪實作。裝置重測依發行驗證清單及測試環境的隔離條件進行。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `occurrence-date-own-identifier` 的開始日優先規則、拒絕理由、已知限制與測試案例。

## Impact

影響拒絕訊息、XCTest、變更紀錄、現行規格及發行驗證清單。
