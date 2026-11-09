## 1. Helper 與設定檔

- [x] 1.1（The dates come from the helper）`plugin/bin/quota-dates.sh`：每期的重置、到期與鬧鐘偏移，以及一條規則能否重現每一期（rule mode 與 per-period mode 的判準）。驗證：`bash plugin/bin/tests/quota-dates.test.sh` 全過（週、月、純日期、clamp、閏年二月、夏令時間、提前量跨月、`--from` 落在重置點、錯誤參數）。
- [x] 1.2（Quotas are declared in one global file）`find-ical-config.sh --quotas`（0 可信、1 不存在、3 存在但不可信；不往上找）。驗證：`bash plugin/bin/tests/find-ical-config.test.sh` 全過，既有 18 項不變。
- [x] 1.3 CI 跑兩個 shell 測試。驗證：`.github/workflows/test.yml` 有對應步驟。

## 2. Skill 與文件

- [x] 2.1 `plugin/skills/quota/SKILL.md`：五個操作、設定檔的封閉鍵表、提醒的欄位與 notes 範本與標記（The reminder has one shape）、讀回（Writes are read back）、更新與逾期的那一則不移動（An update edits the reminder in place）、退役（A retirement asks first）、清單與同步（List and sync）、報告、虛構實例。驗證：對照 spec 逐條；`QuotaSkillDocsTests` 釘住範本、標記、設定檔路徑與 helper 名稱。
- [x] 2.2 `plugin/README.md`、`plugin/CLAUDE.md`、`plugin/CHANGELOG.md` 的 `[Unreleased]`。驗證：skill 列在 README 的 Skills 表與 CLAUDE.md 的 Skills 段；changelog 寫明需要 #333 與 #354 的 binary。

## 2b. Verify 第 1 輪的修正

- [x] 2b.1（Each period has a stable identity）每一期有固定的識別：helper 輸出 `key`（重置日）與 `state`、`--previous` 列出上一期；per-period 的提醒帶 `Period:` 行，rule mode 由 due 讀出期別；以期別比對、不按順序；完成或已過重置的那一則不再被移動、配對或提議刪除；rule mode 不把已往前滾的提醒移回；沒用完時 rule mode 會停住：停住的系列以「保留未勾的紀錄、提議重啟」處理；`list` 每一種情況的回報寫成封閉列舉。驗證：`QuotaSkillDocsTests` 的 period-model、list、marker、引數、Schedule 行釘選；實機檢查 3.1b。
- [x] 2b.2 helper：十進位（`08`、`09`、`010`）、命令替換裡的失敗會停下、時區檔要是 TZif、提前量上限；`--quotas` 檢查要寫入的目錄與 symlink 的目標。驗證：兩個 shell 測試檔全過。

## 2c. Verify 第 2 輪的修正

- [x] 2c.1（Each period has a stable identity；An update edits the reminder in place；List and sync）歷史邊界只由已用的期別決定（已完成的提醒；rule mode 中未完成提醒滾過的期別），未完成提醒自己的期別不算；要重新配對的是尚未重置的未完成提醒。規劃由新的 `quota-plan.sh` 算，skill 不再手動推。驗證：`quota-plan.test.sh`（重置提前、延後、per-period 多則未來提醒、清掉後不重建、停兩期以上的重啟、手改日期不建立、模稜兩可）。
- [x] 2c.2 update 先比新舊模式（`notify_at` 也會翻轉）；`local_tz` 在 declare 時釘住並一律傳入；主機在別的時區時不寫入；`mode`、`per_period_through`、`retiring` 由 skill 寫入；互為前綴的 id 無效；第一次 declare 沒有 `~/.claude` 時看最近存在的上層；symlink 的 `.ical` 看實體路徑的上層；helper 的數字最多六位、計算失敗一律停下。驗證：三個 shell 測試檔、`QuotaSkillDocsTests`。

## 2d. Verify 第 3 輪的修正

- [x] 2d.1（Each period has a stable identity；寫入時的模式（verify 第 3 輪））planner 必須知道既有提醒是用哪個模式寫的（`--written-mode`，取自 entry 的 `mode`；沒有就只回 `repair-needed`）：只有 rule mode 寫的系列才算「滾過」前面的期別，rule mode 一律用到期日配對、忽略殘留的 `Period:` 行；同一期但到期日或鬧鐘不同的是 `rewrite`（寫入新的到期日），`list`／`sync` 報為 dates changed、不默默 keep；模稜兩可的提醒擋住它可能所屬的期別（`hold`）；一律依到期日排序；重啟選到期日最晚的紀錄；`--repair` 也遵守 `--through`；在別的清單找到的提醒佔住它的期別、不寫入；每次答 yes 之後重新搜尋、重新規劃再寫入。驗證：`quota-plan.test.sh` 的每個重現案例，且斷言實際寫入的 due。

## 3. 實機檢查

- [x] 3.1 以 repo 內 build 的 binary 的 `--cli`，在名稱含 `#327` 的拋棄式清單：每週帶提前量與 `notify_at`、每月純日期、就地更新、完成後滾到下一期。驗證：讀回到期、鬧鐘與規則；更新後識別碼不變、標記以下文字保留；清單刪除後隔一分鐘以上 `list_calendars` 兩次無 `#327`。
- [x] 3.1b Verify 第 1 輪之後重做（拋棄式 `#327` 清單，讀取都限定該清單）：rule mode 在重置前打勾後的狀態、per-period 的 `Period:` 行、停住的系列以 `clear_recurrence` 改成一次性且到期日不變。
- [ ] 3.2 下一個 binary release 之後，在重啟後的 session MCP 上走一次 `declare`、`update`、`list`、`retire`（拋棄式清單）。
