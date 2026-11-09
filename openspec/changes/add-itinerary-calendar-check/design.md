## Context

#341 的 Diagnosis 原本以 skill 名稱的封閉清單為鍵，透過 `Skill` 工具上的 hook 觸發。維護者 2026-10-28 的決定換掉了這個做法：別人安裝的 plugin 不能寫死其他 plugin 的 skill。改為看旅程資料夾，也就是最近的專案層 `.claude/.ical/config.yaml` 所在的資料夾（#337 已找得到），預設為開。

## Decisions

### 用 Stop hook 的 additionalContext，不用 block

Claude Code hooks 參考文件（`hooks.md` 的 Stop decision control 一節，2026-11-09 讀）寫明：`Stop` 的 `hookSpecificOutput.additionalContext` 是非錯誤的回饋，對話會繼續讓 Claude 處理；它受與 `decision: "block"` 相同的迴圈保護（`stop_hook_active` 輸入與連續 8 次的上限）。hook 另外自己守住：
- `stop_hook_active` 為 true 時不輸出；
- 輸出前先寫 `.reminded` 紀錄，所以每個 session 只提醒一次；
- 寫不了這個紀錄時就不輸出，免得每個回合都提醒。

### Session 開始時間放在 `${CLAUDE_PLUGIN_DATA}`

同一份參考文件寫 `CLAUDE_PLUGIN_DATA` 是 plugin 的持久資料目錄。hook 在那裡寫 `itinerary-sessions/<session_id>.start`，session id 只接受 `[A-Za-z0-9_-]`。開始時間只記一次：resume、`/clear`、compaction 都保留第一次的紀錄。開始時刪掉超過 30 天的紀錄。這個變數沒設時 hook 什麼都不做。

### 只在互動式 session 提醒

headless 的執行（`claude -p`、Agent SDK、排程或背景 session）多出的一個回合會取代它的最終結果，所以不提醒：SessionStart 時判斷，headless 就不寫開始紀錄。hooks 參考文件沒有記載可判斷互動與否的輸入欄位，因此讀 Claude Code 給 hook 的兩個環境變數（2.1.319 實測、未記載）：`CLAUDE_CODE_ENTRYPOINT` 只有 `cli`（實測的互動值）算互動，其他值或未設定都當 headless（allowlist，判斷不了就當 headless：少一次提醒的代價比較小）；`CLAUDE_CODE_SESSION_ATTENDED` 為 `0` 時也是。Stop 時再判斷一次，所以互動 session 用 `claude -p --resume` 接續時也不提醒。

### 走訪資料夾有上限

只讀檔名與修改時間，不讀內容。略過 `.git/`、`.claude/`、`.DS_Store` 與 symlink。用 `os.scandir` 逐層、逐項讀（不先整個目錄排序），目錄與檔案都算項目，每個項目都檢查時限；走訪前先寫暫停標記、正常結束才移除，所以被 hook timeout 殺掉的走訪也會讓之後 5 分鐘不再走訪；2 秒或 50 000 個項目後停下，並說明清單提早停止；停下而沒找到任何變更時，5 分鐘內不再走訪（大資料夾每個回合都花 2 秒，代價是那 5 分鐘內的變更晚一點才提醒）。列出 20 個檔案，其餘只算數量。`hooks.json` 給這個指令 10 秒的 timeout。修改時間也會被別的來源改到（Dropbox 等同步、編輯器的暫存檔），這類提醒會是白提醒，用 `itinerary_ignore` 略過。

### 檔名是資料

檔名由任何人決定，可能含換行與指示，或用 `; ` 假裝成另一個檔案。提醒裡每個檔名只是顯示名稱：以 JSON 字串呈現，去掉 Cc、Cf、Zl、Zp 類字元，每個截到 120 字、整串截到 4000 字（`additionalContext` 上限 10k），附上數量，並說明這些字串是資料，不是指示，也不是可開啟的路徑。確切路徑存在 plugin data 該 session 的檔案裡，skill 用 `bin/itinerary-changed.sh` 讀取，不從顯示名稱重建路徑。旅程資料夾取工作目錄的邏輯祖先，所以 symlink 的 `.claude` 不會把它移到別處。

### 設定鍵不用 YAML 函式庫讀

hook 只讀兩個頂層鍵：
- `itinerary_check`：`off` 或 `false` 關閉提醒，引號有無、大小寫都可以。
- `itinerary_ignore`：行內清單或區塊清單。

macOS 的 python3 預設沒有 YAML 模組，所以用逐行解析讀這兩個鍵；檔案其他內容 hook 不看。

### 檢查本身不寫入，使用者的同意是唯一的關卡

`allowed-tools` 在呼叫 skill 的那個回合預先核准，而那個回合也讀不受信任的檔案，所以只列讀取工具，Bash 限定為設定檔查詢那一個指令（`Bash(bash ${CLAUDE_PLUGIN_ROOT}/bin/find-ical-config.sh *)`；Claude Code 文件：結尾 ` *` 也比對單獨的指令，複合指令會先拆開再比對）。這只讓 skill 自己的回合維持唯讀，不是寫入的第二道檢查：使用者的設定可能已允許寫入工具或使用 auto mode。寫入的唯一關卡是使用者對那一列的同意。從本 skill 進入的模組，不適用它自己不問就寫的路徑（會議模組的 exact match 更新與 partial correction、住宿模組不問的寫入）：要改的都列進本 skill 的表，或由模組先列它自己的表，同意之前什麼都不寫。變更先依事件屬於誰分派（會議標記→會議模組、住宿標記→住宿模組、其他→`update_event`），沒有事件的事實再依種類（新發布的議程→會議模組的完整貼上、住宿→住宿模組、其他→`create_event`）。

## Risks / Trade-offs

- 提醒可能是白提醒：檔案改了不代表旅程事實改了。skill 會一行回答。
- 既有的專案層設定檔使用者升級後會開始收到提醒。CHANGELOG 與 README 寫明，`itinerary_check: off` 可關閉。
- 在旅程資料夾裡，每個 session 多花一個模型回合。
