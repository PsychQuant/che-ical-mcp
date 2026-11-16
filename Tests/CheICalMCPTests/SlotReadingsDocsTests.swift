import Foundation
import XCTest
@testable import CheICalMCP

/// #539, #541: the documents say how the undo reads an occurrence edited while its series had no time
/// zone, and what `clear_timezone` leaves. Each phrase occurs exactly once in its document (a
/// `contains()` pin survives a restatement that drifted, the repo's docs-pin rule).
final class SlotReadingsDocsTests: XCTestCase {
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

    func testTheReadmesSayHowTheUndoReadsAnOccurrenceEditedWithoutATimeZone() throws {
        try assertOnce(["**A series with no time zone (#539):**",
                        "and use the reading that falls on a slot of the series",
                        "and restores none of the exceptions when one cannot be placed",
                        "was listed from 03:30 to 03:00, ending before it starts",
                        "Not measured: a store other than iCloud, and a server whose time zone changed between the delete and the undo."], in: "README.md")
        try assertOnce(["**沒有時區的系列（#539）：**",
                        "並採用落在系列場次上的那一種",
                        "所有例外都不還原",
                        "列成 03:30 開始、03:00 結束",
                        "沒有量過：iCloud 以外的 store"], in: "README_zh-TW.md")
    }

    func testTheReadmesSayWhatClearTimezoneLeaves() throws {
        try assertOnce(["leaves a timed event floating, not in the system time zone (#541)"], in: "README.md")
        try assertOnce(["會讓計時事件變成浮動，不是改用系統時區（#541）"], in: "README_zh-TW.md")
    }

    func testTheReleaseGateListsTheCellsAndWhatWasNotMeasured() throws {
        try assertOnce(["## Release gate：沒有時區的系列，修改過的場次在 undo 裡的讀法（#539）",
                        "2026-11-16 已在 iCloud 用 `83d2418a` 的簽章 release build",
                        "主機時區的夏令時間切換日修改的場次",
                        "8. **B1**（`delete_events_batch`）",
                        "9. **預告（N1–N3）**",
                        "2026-11-17 用 `3587d72e`",
                        "刪除時的預告不數放得上去、但結束在開始之前的紀錄",
                        "的提案在 #553",
                        "#509 的規則結束檢查；計畫第 5 步、mutant 11）在 #557。"], in: ".claude/rules/mcp-binary-version-testing.md")
    }

    /// #539 step 6: the documents say when a whole-series delete forecasts an undo from the rules alone.
    func testTheDocumentsSayWhenTheDeleteForecastsTheRulesAlone() throws {
        try assertOnce(["**The forecast at the delete (#539):**",
                        "`delete_events_batch` lists such rows under `rules_alone_on_undo`, each with its `event_id` and `undo_note`",
                        "and its dry run with span \"future\" does not",
                        "nor for a record that is placed but ends before it starts"], in: "README.md")
        try assertOnce(["**刪除時的預告（#539）：**",
                        "`delete_events_batch` 把這種列放在 `rules_alone_on_undo`",
                        "span \"future\" 的 dry run 不給"], in: "README_zh-TW.md")
        try assertOnce(["**A whole-series delete says when its undo is expected to restore the series from its rules alone** (#539)",
                        "(step 4, its mutant 10 and device cells MB and R1; proposed on #553)",
                        "(step 5, mutant 11; #557)"], in: "CHANGELOG.md")
    }
}
