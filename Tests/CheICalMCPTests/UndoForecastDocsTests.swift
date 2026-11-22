import Foundation
import XCTest
@testable import CheICalMCP

/// #539, #541: the documents say how every undo reads an occurrence edited while its series had no time zone
/// (as an instant, `main`'s), what a whole-series delete forecasts, and what `clear_timezone` leaves. Each
/// phrase occurs exactly once in its document (a `contains()` pin survives a restatement that drifted, the
/// repo's docs-pin rule). PR #558 fix round 5 removed rulings F and J, so no document describes them (this file
/// was `SlotReadingsDocsTests`, named after the type that went with them).
final class UndoForecastDocsTests: XCTestCase {
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

    private func assertNone(_ phrases: [String], in relative: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try repoFile(relative)
        for phrase in phrases {
            XCTAssertFalse(text.contains(phrase), "\(relative): \(phrase)", file: file, line: line)
        }
    }

    /// The claims of the rulings fix round 5 removed (F's refusal, J's reading of the series' zone), and of the
    /// forecast's old wording (Q9), in every document that held them.
    private let retired = ["since this server cannot tell which reading is the slot",
                           "only an occurrence not edited on its own is at the time the same digits name",
                           "read on the series (through the part of the occurrence's identifier before `/RID=`",
                           "never worse than `main`", "seldom matches", "its edits lost",
                           "every occurrence edited on its own comes back without its edit"]

    func testTheReadmesSayHowTheUndoReadsAnOccurrenceEditedWithoutATimeZone() throws {
        try assertOnce(["**A series with no time zone (#539, not fixed):**",
                        "The whole-series delete undo and the #321 slot check in the undo of an occurrence delete or a split move's source read timed RIDs as instants and all-day RIDs by local day, as before #539.",
                        "**These are `main`'s own; #539 stays open for them.**",
                        "PR #558 changed these undos in five rounds, and each verify round found a shape in which its version did worse than before, so they are as they were;"], in: "README.md")
        try assertOnce(["**沒有時區的系列（#539，沒有修好）：**",
                        "非全天場次的 RID 讀成時刻，全天場次依本地日期讀取。",
                        "**這些是 `main` 本身的行為；#539 保持 open 給它們。**",
                        "PR #558 前後五輪改過這些 undo，"], in: "README_zh-TW.md")
        try assertNone(retired + ["a matrix test shows that leaving", "its slot is removed with the occurrence",
                                  "the undo is refused, nothing is written and the entry is kept, since"], in: "README.md")
        try assertNone(["分不出哪一種讀法才是那個場次", "它的場次連同場次本身被移除"], in: "README_zh-TW.md")
    }

    func testTheReadmesSayWhatClearTimezoneLeaves() throws {
        try assertOnce(["clears the event's zone (#541)", "Floating calendar times express local wall-clock time",
                        "It reads a timed RID as an instant and an all-day RID by its local day.",
                        "A stale slot can also differ at UTC after a move."], in: "README.md")
        try assertOnce(["會清除事件的時區（#541）", "浮動的日曆時間表示當地鐘面時間",
                        "#503 拒絕了那次整個系列的時區寫入",
                        "系列移動後留下的舊時段在 UTC 也可能對不上。"], in: "README_zh-TW.md")
        try assertOnce(["The nonzero offset affects the timed RID’s wall-clock-as-instant reading",
                        "An all-day RID is read by its local day.",
                        "A stale RID after a series move can be off-slot even at UTC."], in: "CHANGELOG.md")
    }

    func testTheReleaseGateListsTheCellsAndWhatWasNotMeasured() throws {
        try assertOnce(["## Release gate：整個系列刪除的預告（#539）", "**#539 維持開啟。**",
                        "1. **E1**：", "2. **E2**：", "3. **E3**：", "4. **E4**（對照）：", "5. **B1**：", "6. **B2**：",
                        "7. **E5**（對照）：", "每格只啟動該 binary 的一個獨立 stdio 程序",
                        "確認第 3 場自己的 id 與篩選列出的 id 相同", "**Verify-fix (round 7)**",
                        "複查只查詢本次建立的拋棄式行事曆名稱",
                        "依 ID 刪除本次建立的日曆",
                        "版本打 tag 前的結果記在 #539",
                        "E3 的 UTC 結果由固定時差的單元測試檢查",
                        "15,696 格中有 2,324 格兩邊都未執行 undo"], in: ".claude/rules/mcp-binary-version-testing.md")
        try assertNone(["19ab96dd", "11:02:47 與 11:03:52"], in: ".claude/rules/mcp-binary-version-testing.md")
    }

    func testTheDocumentsSayWhenTheDeleteForecastsTheRulesAlone() throws {
        try assertOnce(["**The forecast at the delete (#539):**", "the same recurrence time zone at undo",
                        "an offset change or an ambiguous window or rule-end boundary",
                        "The store may list different slots at undo.", "more than 20,000 expanded slots",
                        "A delete without the note can still come back from its rules alone.",
                        "returned date-range rows that inherit its answer", "16 extra store listings per call",
                        "**Verify-fix (round 7)**"], in: "README.md")
        try assertOnce(["**刪除時的預告（#539）：**", "時差變動，或視窗及規則截止日的邊界無法判定",
                        "儲存服務實際列出的時段可能不同",
                        "即使沒有預告，undo 仍可能只依規則重建系列。",
                        "同系列已有成功前列", "16 次額外的儲存服務列舉", "**Verify-fix (round 7)**"], in: "README_zh-TW.md")
        try assertOnce(["timed RIDs as instants, all-day RIDs by local day",
                        "A delete without the note can still come back from its rules alone.",
                        "The 2,324 failed resolutions run neither undo.", "For the other 13,372 cells",
                        "**Verify-fix (round 7)**", "**#539 is not fixed:**",
                        "the #539 plan’s step 4, mutant 10 and device cells MB and R1",
                        "the #539 plan’s step 5 and mutant 11"], in: "CHANGELOG.md")
        try assertNone(retired, in: "CHANGELOG.md")
        try assertNone(retired, in: "README.md")
        try assertOnce(["An edited occurrence's recorded slot is read as an instant, and a whole-series delete forecasts its undo",
                        "as an instant; an all-day one as its local day", "A delete without the note can still come back from its rules alone.",
                        "both edits are captured using the slots as recorded", "after a successful earlier row of the same series",
                        "16 additional store listings per call", "The store may list different slots at undo.",
                        "its captured edit has a slot absent from the eligible model"],
                       in: "openspec/specs/undo-history-discard/spec.md")
    }
}
