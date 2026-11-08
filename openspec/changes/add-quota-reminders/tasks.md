## 1. Helper 與設定檔

- [x] 1.1（The dates come from the helper）`plugin/bin/quota-dates.sh`：每期的重置、到期與鬧鐘偏移，以及一條規則能否重現每一期（rule mode 與 per-period mode 的判準）。驗證：`bash plugin/bin/tests/quota-dates.test.sh` 全過（週、月、純日期、clamp、閏年二月、夏令時間、提前量跨月、`--from` 落在重置點、錯誤參數）。
- [x] 1.2（Quotas are declared in one global file）`find-ical-config.sh --quotas`（0 可信、1 不存在、3 存在但不可信；不往上找）。驗證：`bash plugin/bin/tests/find-ical-config.test.sh` 全過，既有 18 項不變。
- [x] 1.3 CI 跑兩個 shell 測試。驗證：`.github/workflows/test.yml` 有對應步驟。

## 2. Skill 與文件

- [x] 2.1 `plugin/skills/quota/SKILL.md`：五個操作、設定檔的封閉鍵表、提醒的欄位與 notes 範本與標記（The reminder has one shape）、讀回（Writes are read back）、更新與逾期的那一則不移動（An update edits the reminder in place）、退役（A retirement asks first）、清單與同步（List and sync）、報告、虛構實例。驗證：對照 spec 逐條；`QuotaSkillDocsTests` 釘住範本、標記、設定檔路徑與 helper 名稱。
- [x] 2.2 `plugin/README.md`、`plugin/CLAUDE.md`、`plugin/CHANGELOG.md` 的 `[Unreleased]`。驗證：skill 列在 README 的 Skills 表與 CLAUDE.md 的 Skills 段；changelog 寫明需要 #333 與 #354 的 binary。

## 3. 實機檢查

- [x] 3.1 以 repo 內 build 的 binary 的 `--cli`，在名稱含 `#327` 的拋棄式清單：每週帶提前量與 `notify_at`、每月純日期、就地更新、完成後滾到下一期。驗證：讀回到期、鬧鐘與規則；更新後識別碼不變、標記以下文字保留；清單刪除後隔一分鐘以上 `list_calendars` 兩次無 `#327`。
- [ ] 3.2 下一個 binary release 之後，在重啟後的 session MCP 上走一次 `declare`、`update`、`list`、`retire`（拋棄式清單）。
