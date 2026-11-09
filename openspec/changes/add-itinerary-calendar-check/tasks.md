## 1. Spike

- [x] 1.1 讀 Claude Code hooks 參考文件：`Stop` hook 的 `additionalContext` 讓對話繼續，受 `stop_hook_active` 與連續 8 次上限保護；`CLAUDE_PLUGIN_DATA` 是 plugin 的持久資料目錄。驗證：design 引用讀過的章節。
- [ ] 1.2 在實際的 Claude Code session 裡，於有專案層設定檔的虛構旅程資料夾改一個檔案、結束一個回合。驗證：提醒出現一次、Claude 回應它、session 沒有第二次被延續。另外在互動 session 裡啟動的 `claude -p`（從該 session 的 Bash 執行）結束時不提醒：記下它讀到的 `CLAUDE_CODE_ENTRYPOINT` 與 `CLAUDE_CODE_SESSION_ATTENDED`（背景 job 也是 `cli`，只靠 `ATTENDED=0` 排除）。需要有人在鍵盤前操作，尚未做。

## 2. Hook

- [x] 2.1 `plugin/hooks/itinerary-reminder.sh` 與 `itinerary_reminder.py`，在 `SessionStart` 註冊 `start`、在 `Stop` 註冊 `stop`，timeout 10 秒（A changed trip folder brings one reminder per session；走訪資料夾有上限；Session 開始時間放在 `${CLAUDE_PLUGIN_DATA}`）。驗證：`bash scripts/tests/itinerary-reminder-test.sh` 通過，且 CI workflow 會跑它。
- [x] 2.2 設定鍵 `itinerary_check` 與 `itinerary_ignore`（The reminder is on by default and can be turned off or narrowed；設定鍵不用 YAML 函式庫讀）。驗證：hook 測試涵蓋 `off`、`"off"`、`'off'`、`false`、行尾註解、`on`、區塊清單與行內清單。

## 3. Skill 與文件

- [x] 3.1 `plugin/skills/itinerary-check/SKILL.md`（The check lists differences and changes nothing until the user agrees；檢查本身不寫入，使用者的同意是唯一的關卡）。驗證：spec 的每個 requirement 在 skill 裡都有對應文字，逐一對照情境審閱。
- [x] 3.3 第 1 輪驗證的修正（PR #500）：`allowed-tools` 的 Bash 限定為設定檔查詢；檔名是資料（JSON 字串、宣告為資料）；走訪計入目錄；旅程資料夾取邏輯祖先；目錄樣式用 glob；只在互動式 session 提醒；寫入依事件屬於誰分派。驗證：hook 測試與 `ItineraryCheckDocsTests` 先紅後綠。
- [x] 3.4 第 6 輪驗證的修正（PR #500）：寫入端以根目錄逐層描述子開啟資料目錄、走訪以描述子逐層開啟並 scandir、紀錄檔拒絕其他硬連結、引號只在值的開頭開啟、開頭 `/` 的目錄樣式錨定在旅程資料夾、helper 的 `complete`／`total` 限定型別。驗證：hook 測試先紅後綠。
- [x] 3.5 第 7 輪驗證的修正（PR #500）：只有完整檢查才給 all-clear、真實路徑規則兩邊都 resolve、經 symlink 進入的工作目錄退回真實路徑的祖先、引號與跳脫規則統一、helper 拒絕非相對的檔案路徑與非絕對的旅程資料夾與空的 `HOME`、清理略過本 session 的紀錄、wrapper `exec` python。驗證：hook 測試與 `ItineraryCheckDocsTests` 先紅後綠。
- [x] 3.2 `plugin/CLAUDE.md`、`plugin/README.md`、`plugin/CHANGELOG.md`，以及 `plugin/rules/event-modules.md` 的一行指引。驗證：`ItineraryCheckDocsTests` 通過。
