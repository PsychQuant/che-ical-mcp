## 1. 行為測試
- [x] 1.1 Stable history identity／穩定紀錄身分：測試 ID 在失敗還原後不變、history/counts 一致。
- [x] 1.2 Explicit top record removal：測試事件/提醒事項交錯、重送、錯誤型別、空堆疊與 redo 不變。
- [x] 1.3 Stale and busy protection／原子移除與執行鎖：測試 beginUndo/beginRedo 期間拒絕移除及第二次 begin，finish/restore 後可繼續。
## 2. 實作
- [x] 2.1 實作 actor 原子 discard 與穩定 ID，通過上述 stack tests。
- [x] 2.2 串接 undo(discard_id) 與 undo_history，透過注入的歷史 manager 做 handler tests，無 EventKit 存取。
- [x] 2.3 更新工具描述、manifest 與文件，固定 opt-in 操作與錯誤語意；對照規格審閱。
## 3. 驗證
- [x] 3.1 完整 swift test、獨立 reviewer、spectra analyze/validate 通過；各 issue 寫回 Implementation Complete 與驗證紀錄。
