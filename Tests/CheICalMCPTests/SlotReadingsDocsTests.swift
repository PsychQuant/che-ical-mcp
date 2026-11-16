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
                        "Not measured: a store other than iCloud, an edit on a daylight-saving day"], in: "README.md")
        try assertOnce(["**沒有時區的系列（#539）：**",
                        "並採用落在系列場次上的那一種",
                        "所有例外都不還原",
                        "沒有量過：iCloud 以外的 store"], in: "README_zh-TW.md")
    }

    func testTheReadmesSayWhatClearTimezoneLeaves() throws {
        try assertOnce(["leaves a timed event floating, not in the system time zone (#541)"], in: "README.md")
        try assertOnce(["會讓計時事件變成浮動，不是改用系統時區（#541）"], in: "README_zh-TW.md")
    }

    func testTheReleaseGateListsTheCellsAndWhatWasNotMeasured() throws {
        try assertOnce(["## Release gate：沒有時區的系列，修改過的場次在 undo 裡的讀法（#539）",
                        "2026-11-16 已在 iCloud 用 `83d2418a` 的簽章 release build",
                        "主機時區的夏令時間切換日修改的場次"], in: ".claude/rules/mcp-binary-version-testing.md")
    }
}
