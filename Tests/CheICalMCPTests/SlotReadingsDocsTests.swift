import Foundation
import XCTest
@testable import CheICalMCP

/// #539, #541: the documents say how the undo reads an occurrence edited while its series had no time
/// zone, and what `clear_timezone` leaves. Each phrase occurs exactly once in its document (a
/// `contains()` pin survives a restatement that drifted, the repo's docs-pin rule).
final class SlotReadingsDocsTests: XCTestCase {
    /// #539 (coordinator ruling 2026-11-17): DS1's limit in Traditional Chinese, as the zh README and the gate say it.
    /// PR #558 round 3: only for a record of one reading.
    static let placedButEndsBeforeStartZH = "原本時間只有一種讀法、而以這台 Mac 讀到的時間結束在開始之前的修改場次（時間落在夏令時間切換）也不給：刪除時沒有說明，undo 照規則重建這個系列"

    private func repoFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func assertOnce(_ phrases: [String], in relative: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try repoFile(relative)
        for phrase in phrases {
            XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, "\(relative): \(phrase)", file: file, line: line)
        }
    }

    /// PR #558 round 3: the placement withdrawn; the READMEs say the edits of such a series are not restored.
    func testTheReadmesSayHowTheUndoReadsAnOccurrenceEditedWithoutATimeZone() throws {
        try assertOnce(["**A series with no time zone (#539):**",
                        "So the undo of a whole-series delete of a series that has no time zone when it is deleted restores none of the series' exceptions when it recorded such an edit",
                        "**The edits of a series with no time zone are not restored by this undo; #539 stays open for that.**",
                        "so the placement was withdrawn. On a Mac at offset 0 the two readings are one instant, and the edit is restored as before #539.",
                        "A series that has a time zone is read as an instant only, as before #539",
                        "brings the edit back and this change does not (read from the code and a matrix test)",
                        "Whether the occurrence's series has a time zone is read on the series (through the part of the occurrence's identifier before `/RID=`",
                        "the undo is refused, nothing is written and the entry is kept, since this server cannot tell which reading is the slot: give it up with `discard_id`.",
                        "after such a restore, undoing the earlier delete of an edited occurrence made through its own identifier (MA) was refused",
                        "Not measured: a store other than iCloud, and a server whose time zone changed between the delete and the undo."], in: "README.md")
        try assertOnce(["**沒有時區的系列（#539）：**",
                        "只要記到這樣的修改，undo 就不還原這個系列的任何例外",
                        "**沒有時區的系列，整個系列刪除的 undo 不還原它的修改；#539 保持 open 給這部分。**",
                        "有時區的系列只讀成時刻，跟 #539 之前一樣",
                        "場次的系列有沒有時區，是在系列上讀的",
                        "undo 拒絕、什麼都不寫並保留紀錄",
                        "列成 03:30 開始、03:00 結束",
                        "沒有量過：iCloud 以外的 store"], in: "README_zh-TW.md")
    }

    func testTheReadmesSayWhatClearTimezoneLeaves() throws {
        try assertOnce(["leaves a timed event floating, not in the system time zone (#541)",
                        "is refused by the #503 check once an occurrence was edited on its own while the series had no time zone (measured on iCloud with this Mac at `+08:00`, #553; on a Mac at UTC the check would not see it)."], in: "README.md")
        try assertOnce(["會讓計時事件變成浮動，不是改用系統時區（#541）",
                        "整個系列的時區寫入會被 #503 的檢查拒絕（iCloud 實測，這台 Mac 在 `+08:00`，#553；在 UTC 的 Mac 上這個檢查看不出來）"], in: "README_zh-TW.md")
        try assertOnce(["is refused by the #503 check once an occurrence was edited on its own while the series had no time zone (measured on iCloud with this Mac at `+08:00`, #553; on a Mac at UTC the check would not see it). Text only."], in: "CHANGELOG.md")
    }

    func testTheReleaseGateListsTheCellsAndWhatWasNotMeasured() throws {
        try assertOnce(["## Release gate：沒有時區的系列，修改過的場次在 undo 裡的讀法（#539）",
                        "**沒有時區的系列的修改不由整個系列刪除的 undo 還原，#539 保持 open 給這部分**",
                        "2026-11-16 已在 iCloud 用 `83d2418a` 的簽章 release build",
                        "主機時區的夏令時間切換日修改的場次",
                        "8. **B1**（`delete_events_batch`）",
                        "9. **預告（N1–N3）**",
                        "2026-11-17 用 `3587d72e`",
                        "- 刪除時的預告：" + Self.placedButEndsBeforeStartZH + "（主機在那個時間的時差為 0 的 Mac，沒有量）。",
                        "它的 `Sources/` 與 `95814269` 相同；round 0 的 head `4668699e` 在 `Sources/` 只多改了 `Server.swift` 裡",
                        "14. **SD**：",
                        "#538 gate 第 1、3 步（#538 Implementation Complete 編號的 sequence 1 與 8）",
                        "11. **S1**（PR #558 verify round 1）",
                        "12. **FR**（#321 檢查的拒絕，裁定 F）",
                        "N2 的回應沒有最上層的",
                        "round 1 修正後用 `6851a4b9` 的簽章 release build",
                        "PR #558 round 2（2026-11-18）的紀錄更正（J5）",
                        "PR #558 round 3（2026-11-18，放置撤回之後）用 `041a5b5f` 的 Developer ID 簽章 release build",
                        "的提案在 #553",
                        "#509 的規則結束檢查；計畫第 5 步、mutant 11）在 #557。"], in: ".claude/rules/mcp-binary-version-testing.md")
    }

    /// #539 step 6: the documents say when a whole-series delete forecasts an undo from the rules alone.
    func testTheDocumentsSayWhenTheDeleteForecastsTheRulesAlone() throws {
        try assertOnce(["**The forecast at the delete (#539):**",
                        "For a series with no time zone that records one whose original time has two readings, the answer carries `undo_note`: undo is expected to bring the series back from its rules alone, because the edits of a series with no time zone are not restored (above)",
                        "`delete_events_batch` lists such rows under `rules_alone_on_undo`, each with its `event_id` and `undo_note`",
                        "and its dry run with span \"future\" does not",
                        "nor for " + ManifestParityTests.placedButEndsBeforeStart + " (the daylight-saving case above)",
                        "(by date range, in the row of every listed occurrence of that series)",
                        "or when an occurrence not edited on its own that the delete records is no slot of that rule, nor for"], in: "README.md")
        try assertOnce(["**刪除時的預告（#539）：**",
                        "沒有時區的系列記到一個原本時間有兩種讀法的修改時，回應帶 `undo_note`",
                        "`delete_events_batch` 把這種列放在 `rules_alone_on_undo`",
                        "span \"future\" 的 dry run 不給",
                        Self.placedButEndsBeforeStartZH + "（上面的夏令時間情形）。"], in: "README_zh-TW.md")
        try assertOnce(["**A whole-series delete says when its undo is expected to restore the series from its rules alone** (#539)",
                        "(step 4, its mutant 10 and device cells MB and R1; proposed on #553)",
                        "(step 5, mutant 11; #557)",
                        "Not covered: " + ManifestParityTests.placedButEndsBeforeStart + ".",
                        "for a rule the expander does not follow, more than one rule or more than 20,000 slots,",
                        "**Undo of a whole-series delete of a series with no time zone says why it brings the series back from its rules alone** (#539)",
                        "**The edits of a series with no time zone are not restored by this undo; #539 stays open for that.** PR #558 placed",
                        "A matrix test over 7,884 shapes",
                        "in 742 of those shapes `main`, reading the stale identifier as an instant, applied the record",
                        "on a zoned series moved 16 hours later the same day, `delete_event` with span `all` carried the note and its undo restored from the rules alone too."], in: "CHANGELOG.md")
    }
}
