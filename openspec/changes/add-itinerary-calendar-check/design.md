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

headless 的執行（`claude -p`、Agent SDK、排程或背景 session）多出的一個回合會取代它的最終結果，所以不提醒：SessionStart 時判斷，headless 就不寫開始紀錄。hooks 參考文件沒有記載可判斷互動與否的輸入欄位，因此讀 Claude Code 給 hook 的兩個環境變數（2.1.319 實測、未記載）：`CLAUDE_CODE_ENTRYPOINT` 只有 `cli`（實測的互動值）算互動，其他值或未設定都當 headless（allowlist，判斷不了就當 headless：少一次提醒的代價比較小）；`CLAUDE_CODE_SESSION_ATTENDED` 為 `0` 時也是。`cli` 本身不代表有人在場：背景 job 的 `CLAUDE_CODE_ENTRYPOINT` 也是 `cli`，只靠 `CLAUDE_CODE_SESSION_ATTENDED=0` 排除（PR #500 第 7 輪驗證的背景 job 實測）；從互動 session 的 Bash 啟動的 `claude -p` 讀到什麼還沒看過，列在 task 1.2。Stop 時再判斷一次，所以互動 session 用 `claude -p --resume` 接續時也不提醒。

### 走訪資料夾有上限

只讀檔名與修改時間，不讀內容。略過 `.git/`、`.claude/`、`.DS_Store` 與 symlink。用 `os.scandir` 逐層、逐項讀（不先整個目錄排序），目錄與檔案都算項目，每個項目都檢查時限；走訪前先寫暫停標記、正常結束才移除，所以被 hook timeout 殺掉的走訪也會讓之後 5 分鐘不再走訪（同一 session 再慢就加倍，最長 1 小時，見第 8 輪）；2 秒或 50 000 個項目後停下，並說明清單提早停止；停下而沒找到任何變更時，5 分鐘內不再走訪，之後每次再慢就加倍到最長 1 小時（大資料夾每個回合都花 2 秒，代價是那 5 分鐘內的變更晚一點才提醒）。列出 20 個檔案，其餘只算數量。`hooks.json` 給這個指令 10 秒的 timeout。修改時間也會被別的來源改到（Dropbox 等同步、編輯器的暫存檔），這類提醒會是白提醒，用 `itinerary_ignore` 略過。

### 檔名是資料

檔名由任何人決定，可能含換行與指示，或用 `; ` 假裝成另一個檔案。提醒裡每個檔名只是顯示名稱：以 JSON 字串呈現，去掉 Cc、Cf、Zl、Zp 類字元，每個截到 120 字、整串截到 4000 字（`additionalContext` 上限 10k），附上數量，並說明這些字串是資料，不是指示，也不是可開啟的路徑。確切路徑存在 plugin data 該 session 的檔案裡，skill 用 `bin/itinerary-changed.sh` 讀取，不從顯示名稱重建路徑。旅程資料夾取工作目錄的邏輯祖先，所以 symlink 的 `.claude` 不會把它移到別處；邏輯祖先都沒有那個設定檔時（工作目錄經 symlink 進入、設定檔在 symlink 目標的上層），改取工作目錄真實路徑的祖先，也就是 finder 找到它的地方。

### 設定鍵不用 YAML 函式庫讀

hook 只讀兩個頂層鍵：
- `itinerary_check`：`off`、`no` 或 `false` 關閉提醒，引號有無、大小寫都可以。
- `itinerary_ignore`：行內清單或區塊清單。

macOS 的 python3 預設沒有 YAML 模組，所以用逐行解析讀這兩個鍵；檔案其他內容 hook 不看。

### 檢查本身不寫入，使用者的同意是唯一的關卡

`allowed-tools` 在呼叫 skill 的那個回合預先核准，而那個回合也讀不受信任的檔案，所以只列行事曆讀取工具與兩個限定範圍的 Bash 指令：設定檔查詢 `Bash(bash "${CLAUDE_PLUGIN_ROOT}"/bin/find-ical-config.sh *)` 與變更清單 helper `Bash(bash "${CLAUDE_PLUGIN_ROOT}"/bin/itinerary-changed.sh *)`，不列 `Read`（工作目錄外的讀取照常跳提示）；Claude Code 文件：結尾 ` *` 也比對單獨的指令，複合指令會先拆開再比對）。這只讓 skill 自己的回合維持唯讀，不是寫入的第二道檢查：使用者的設定可能已允許寫入工具或使用 auto mode。寫入的唯一關卡是使用者對那一列的同意。在本 skill 的路徑上，模組在使用者對本 skill 的表說 yes 之前什麼都不寫（建立、修改、刪除、讀回修正都算）；這是一條性質，不是一份清單，模組的對照表仍提供表格的列。旅程資料夾：提醒來的取 helper JSON 的 `trip_folder`，手動執行取工作目錄的邏輯祖先（hook 的規則），沒有設定檔時先請使用者確認資料夾、確認前不讀任何檔案。符合 `/` 結尾忽略樣式的目錄在走訪前就略過，不佔走訪額度；走訪超過 1 秒而沒找到變更時也暫停，同樣從 5 分鐘起、每次加倍、最長 1 小時。變更先依事件屬於誰分派（會議標記→會議模組、住宿標記→住宿模組、其他→`update_event`），沒有事件的事實再依種類（新發布的議程→會議模組的完整貼上、住宿→住宿模組、其他→`create_event`）。

PR #500 第 7 輪：skill 只有在完整檢查之後才給 all-clear（走訪完整、每個變更路徑都存下而且印得出、印出的路徑都讀過），否則說查了什麼、有幾個沒存或沒讀；真實路徑規則兩邊都 resolve，比對旅程資料夾自己的真實路徑，所以經 symlink 的 `~/Dropbox`（macOS 連到 `~/Library/CloudStorage/Dropbox`）底下的旅程資料夾讀得到檔案；hook 的旅程資料夾在邏輯祖先找不到時退回真實路徑的祖先；`itinerary_ignore` 的行內清單、區塊清單與註解共用一套引號規則（雙引號內 `\"`、`\\`，單引號內 `''`）；helper 把絕對路徑或含空、`.`、`..` 段的路徑算成 unreadable，旅程資料夾不是絕對路徑就 exit 1，`HOME` 空而沒有 `CLAUDE_CONFIG_DIR` 時 exit 2；30 天清理略過本 session 自己的開始紀錄；wrapper 用 `exec` 執行 python，hook timeout 殺掉的就是走訪本身。

PR #500 第 8 輪：走訪時開不了或列不出的目錄、stat 不了的項目都讓清單 `complete: false`，提醒也說有資料夾沒列到，skill 因此不給 all-clear；30 天清理略過本 session 的所有紀錄（`.reminded` 也留著，resume 不會再提醒一次）；wrapper 用 `python3 -I -c` 以 runpy 在 catch-all 裡載入模組、一律 exit 0，模組讀不到時 python 不會 exit 2 而擋住 Stop；同一 session 走訪一再很慢時，暫停 5 分鐘、之後每次加倍，最長 1 小時。背景 job 的 session：devil's advocate 在有人回答的背景 job 裡讀到 `CLAUDE_CODE_SESSION_ATTENDED=0`，主 agent 的 Stop hook 是否也是 0 不知道；若是，這類 session 永遠不提醒。允許清單先不改，task 1.2 加一個只記錄這兩個變數的除錯 Stop hook，README 與 CHANGELOG 寫成已知限制。

PR #500 第 9 輪：清單是逐項讀的，讀到一半失敗（例如離線的 File Provider 回 EIO）時保留已找到的、標成不完整、繼續走其他目錄；時限在每個目錄開始前也檢查，大量空目錄不會超過 2 秒；列出後才被刪掉的檔案或目錄（鎖定檔、暫存檔）不算檢查失敗，清單仍完整；30 天清理只放過自己 session 的紀錄，所以別的 session 先啟動時仍可能清掉舊 session 的 `.reminded`，宣稱縮小成「除非別的 session 先清掉」。

## Risks / Trade-offs

- 提醒可能是白提醒：檔案改了不代表旅程事實改了。skill 會一行回答。
- 既有的專案層設定檔使用者升級後會開始收到提醒。CHANGELOG 與 README 寫明，`itinerary_check: off` 可關閉。
- 在旅程資料夾裡，每個 session 多花一個模型回合。

PR #500 第 6 輪：hook 的寫入端改用與 helper 相同的根目錄規則：根目錄正常開啟，以下每一層（含資料目錄與 sessions 目錄）都相對於上一層以 O_NOFOLLOW 開啟，建立、讀取、寫入、刪除都相對於驗過的描述子；`CLAUDE_PLUGIN_DATA` 不在根目錄底下就什麼都不寫。走訪時每個目錄都從旅程資料夾的描述子逐層以 O_DIRECTORY|O_NOFOLLOW 開啟，再對描述子 scandir（本機 Python 3.13 的 `os.scandir in os.supports_fd` 為 True），所以走訪中途被換成 symlink 的目錄不會被跟隨。紀錄檔不再用 O_TRUNC 開啟：先開、fstat 確認是一般檔案且只有一個連結，才 ftruncate；helper 也拒絕有其他硬連結的清單。引號只在值的開頭才算開啟（`Bob's drafts/` 不需要引號）。開頭是 `/` 的目錄樣式只比對旅程資料夾下的路徑。helper 的 `complete` 只輸出 bool、`total` 只輸出非負整數，其他型別一律換掉。

PR #500 第 5 輪：helper 的根目錄改由 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/` 推得（多帳號並行用 `CLAUDE_CONFIG_DIR`），資料目錄至少要在根目錄下一層、不得有 `.` 或 `..`；根目錄以下逐層用目錄描述子加 O_NOFOLLOW 開啟，清單也從描述子讀，所以祖先目錄是 symlink 也會被拒，檢查與開啟之間沒有空隙。hook 的紀錄檔以 O_NONBLOCK 開啟並 fstat，FIFO 之類不是一般檔案的一律拒絕，不會卡住 hook。`#` 只在引號外才算註解；`itinerary_ignore` 比對前把名稱與樣式都轉成 NFC（macOS 常以 NFD 存放名稱），列出的路徑仍是原本的形式。helper 輸出把計數放在路徑前面。

PR #500 第 4 輪：寫入端也拒絕 symlink（sessions 目錄以 O_NOFOLLOW 開成目錄描述子，紀錄檔都相對於它讀寫、刪除，不跟隨 symlink）；inline `itinerary_ignore` 依引號切逗號；只有結尾是 `/` 的樣式會修剪目錄；helper 用 `python3 -I` 以 UTF-8 印出路徑，不是文字的名稱（lone surrogate）只計數為 unreadable，資料目錄只接受 `~/.claude/plugins/data/` 底下、不含 `..` 的路徑；走訪上限是兩秒或 50 000 個項目、在項目之間檢查，單一系統呼叫卡住時由 hook 的 10 秒 timeout 截斷；skill 讀旅程資料夾自己的 config 與 `state/archives.json` 時不套真實路徑規則（hook 也是這樣），讀不到 config 就停下來問。`allowed-tools` 裡的 `${CLAUDE_PLUGIN_ROOT}`：Claude Code 的 skills 文件（2026-11-09 讀）寫明 plugin skill 的 `${CLAUDE_PLUGIN_ROOT}` 與 `${CLAUDE_PLUGIN_DATA}` 會在 Markdown 內容與 `allowed-tools` 的 Bash 規則兩處代換，所以兩個 helper 照寫的樣子預先核准；live session 還沒看過（task 1.2）。
