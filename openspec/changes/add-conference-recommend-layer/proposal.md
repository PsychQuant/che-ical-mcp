## Why

會議模組的標準模式（#338）每個時段建一個事件，平行場次全部列在 notes。維護者 2026-10-24 要求一個選填的推薦層：不改變有哪些事件，只在每個時段的標題、notes 與地點加上推薦（PsychQuant/che-ical-mcp#346）。標準層以「標題（去掉未報名前綴）加起始時間」比對場次，所以改寫標題的推薦層需要自己的比對規則，否則每次重貼都落到對照表，甚至建出重複事件。

## What Changes

- 新契約檔 `plugin/rules/modules/conference-recommend.md`；`conference.md` 改開頭那段 #346 指標（「第 6 節的每個比較與寫入都用事件的標準形式」與比較用標題）、第 7 行的解析清單，以及第 6 節的「Whose text is whose」例外與建立前的客戶端比對；`add-conference-module` 的 spec 加上區塊行的例外；`event-modules.md` 索引加一列。
- 推薦由呼叫端提供（使用者的訊息或交給的表），模組只定義版面、儲存的狀態與比對。
- 模式：這次的訊息 → 最近設定檔的 `conference_mode: standard | recommend`（與 `conference_module` 同一份設定檔、同一個查找）→ `standard`。推薦只在訊息要求、使用者回答移除、或使用者對寫明推薦會拿掉的對照表列回答 yes 時拿掉；其他情況先問一次要移除還是保留，沒人回答就保留。
- 推薦過的事件在 notes 最上方帶一個區塊：推薦行、備選行、線上連結，以及三行狀態：`conference-recommend-item: <標準標題> | <起始>`（推薦層的項目識別碼）、`conference-recommend-location: <標準地點>`、`conference-recommend-marks: <加了標記的行號>`。標準流程讀這類事件時一律讀它的標準形式，所以重貼照常以標準標題加起始時間比對。
- 關掉推薦就是把標準形式寫回去；重新計算推薦按被點名的時段套用新推薦。推薦層只改標題、地點、notes，不改時間、日曆、提醒，不建立也不刪除事件。
- 不寫會議密碼或任何存取碼。
- 新 spec 能力 `conference-recommend-layer`（只有 ADDED），不依賴 `add-conference-module` 先封存。不改 Swift、不發 binary。

## Non-Goals

- 不替使用者挑演講、不產生推薦理由。
- 不建每場演講一個事件。
- 不保證會議連結事後仍有效。
