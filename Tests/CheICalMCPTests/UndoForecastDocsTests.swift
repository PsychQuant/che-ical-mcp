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
    private let retired = ["since this server cannot tell which reading is the slot", "give it up with `discard_id`",
                           "only an occurrence not edited on its own is at the time the same digits name",
                           "read on the series (through the part of the occurrence's identifier before `/RID=`",
                           "never worse than `main`", "seldom matches", "its edits lost",
                           "every occurrence edited on its own comes back without its edit"]

    func testTheReadmesSayHowTheUndoReadsAnOccurrenceEditedWithoutATimeZone() throws {
        try assertOnce(["**A series with no time zone (#539, not fixed):**",
                        "Every undo reads that part as an instant, as before #539: the undo of a whole-series delete, and the check of #321 in the undo of an occurrence's delete (or of a split move's source) whether the restored series already holds its slot.",
                        "**These are `main`'s own; #539 stays open for them.**",
                        "PR #558 changed these undos in five rounds, and each verify round found a shape in which its version did worse than before, so they are as they were;"], in: "README.md")
        try assertOnce(["**沒有時區的系列（#539，沒有修好）：**",
                        "每一個 undo 都把這段讀成時刻，跟 #539 之前一樣：",
                        "**這些是 `main` 本身的行為；#539 保持 open 給它們。**",
                        "PR #558 前後五輪改過這些 undo，"], in: "README_zh-TW.md")
        try assertNone(retired + ["a matrix test shows that leaving", "its slot is removed with the occurrence"], in: "README.md")
        try assertNone(["分不出哪一種讀法才是那個場次", "它的場次連同場次本身被移除"], in: "README_zh-TW.md")
    }

    func testTheReadmesSayWhatClearTimezoneLeaves() throws {
        try assertOnce(["leaves a timed event floating, not in the system time zone (#541)",
                        "On iCloud with this Mac at `+08:00`, a whole-series time zone write on a series with such an occurrence was refused by the #503 check (#553): the check reads that time as an instant too, so it sees the occurrence off its slot only on a Mac not at offset 0 at that time, and only within the dates it lists (#506)."], in: "README.md")
        try assertOnce(["會讓計時事件變成浮動，不是改用系統時區（#541）",
                        "在 iCloud 上、這台 Mac 在 `+08:00` 時，有這種場次的系列，整個系列的時區寫入被 #503 的檢查拒絕（#553）"], in: "README_zh-TW.md")
        try assertOnce(["it reads that time as an instant, so it sees such an occurrence off its slot only on a Mac not at offset 0 at that time, and only within the dates it lists (#506). Text only."], in: "CHANGELOG.md")
    }

    func testTheReleaseGateListsTheCellsAndWhatWasNotMeasured() throws {
        try assertOnce(["## Release gate：整個系列刪除的預告（#539）",
                        "**沒有時區的系列的修改不由 undo 還原，#539 保持 open。**",
                        "PR #558 只加上兩件事：",
                        "1. **E1**：", "2. **E2**：", "3. **E3**：", "4. **E4**（對照）：", "5. **B1**：", "6. **B2**：",
                        "不透明 id（`/RID=` 只在 external identifier 裡）的 dry run 形狀在 iCloud 上做不出來"], in: ".claude/rules/mcp-binary-version-testing.md")
        try assertNone(["## Release gate：沒有時區的系列，修改過的場次在 undo 裡的讀法（#539）", "永遠不比 `main` 差", "裁定 F 在另一個主機時區"],
                       in: ".claude/rules/mcp-binary-version-testing.md")
    }

    /// #539 step 6: the documents say when a whole-series delete forecasts that its undo's check applies none
    /// of the recorded exceptions, and no more than that check establishes (fix round 5, Q9, Q11).
    func testTheDocumentsSayWhenTheDeleteForecastsTheRulesAlone() throws {
        try assertOnce(["**The forecast at the delete (#539):**",
                        "against the slots the series' rule gives from its first slot to the end of the last window it records, as the #503 check expands it.",
                        "the undo's check is expected to apply none of the recorded exceptions, and the answer carries `undo_note` with the number of such records: undo is expected to recreate the series from its rule, with no edited occurrence written back as a one-off event and no slot of it removed.",
                        "`delete_events_batch` lists such rows under `rules_alone_on_undo`, each with its `event_id` and `undo_note`",
                        "leaving out, by their identifiers, the occurrences that the call's earlier rows delete, as the real call does, and its dry run with span \"future\" does not.",
                        "(by date range, in the row of every listed occurrence of that series)",
                        "when that rule gives more than 20,000 slots from the first slot to the end of that window",
                        "a delete through the first edited occurrence (#428) records nothing to restore and gives its own note."], in: "README.md")
        try assertOnce(["**刪除時的預告（#539）：**",
                        "`delete_events_batch` 把這種列放在 `rules_alone_on_undo`",
                        "並且跟實際呼叫一樣，以識別碼排除同一次呼叫裡較早的列刪掉的場次；span \"future\" 的 dry run 不給。",
                        "規則從第一個場次到那個視窗結尾給出超過 20,000 個場次"], in: "README_zh-TW.md")
        try assertOnce(["**A whole-series delete says when its undo's check is expected to apply none of the recorded exceptions** (#539)",
                        "leaving out the occurrences the call's earlier rows delete, by their identifiers, before its record reduces them to slots, as the real call's record no longer holds them (PR #558 verify rounds 4 and 5, C3 and Q2)",
                        "a rule that gives more than 20,000 slots from the first slot to the end of that window,",
                        "**The undo of a whole-series delete, and of an occurrence's delete after it, compared with `main`'s** (#539, PR #558)",
                        "given the same resolution of the series and the same recreated slots",
                        "**#539 is not fixed:**",
                        "(step 4, its mutant 10 and device cells MB and R1; proposed on #553)",
                        "(step 5, mutant 11; #557)"], in: "CHANGELOG.md")
        try assertNone(retired + ["**The undo of one occurrence's delete is refused where a restored series with no time zone may already hold it**",
                                  "more than one rule or more than 20,000 slots,"], in: "CHANGELOG.md")
        try assertNone(retired, in: "README.md")
    }
}
