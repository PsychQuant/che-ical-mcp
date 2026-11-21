import Foundation
import XCTest
@testable import CheICalMCP

/// #539, #541: the documents say how the undo reads an occurrence edited while its series had no time
/// zone, and what `clear_timezone` leaves. Each phrase occurs exactly once in its document (a
/// `contains()` pin survives a restatement that drifted, the repo's docs-pin rule). PR #558 fix round 4:
/// the whole-series undo is `main`'s; the documents say what this PR keeps and that #539 is not fixed.
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

    private func assertNone(_ phrases: [String], in relative: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try repoFile(relative)
        for phrase in phrases {
            XCTAssertFalse(text.contains(phrase), "\(relative): \(phrase)", file: file, line: line)
        }
    }

    func testTheReadmesSayHowTheUndoReadsAnOccurrenceEditedWithoutATimeZone() throws {
        try assertOnce(["**A series with no time zone (#539, not fixed):**",
                        "The undo of a whole-series delete reads that part as an instant for every series, as before #539.",
                        "**These are `main`'s own; #539 stays open for them.**",
                        "PR #558 changed this undo in four rounds, and each verify round found a shape in which its version did worse than before, so the undo is as it was.",
                        "the undo is refused, nothing is written and the entry is kept, since this server cannot tell which reading is the slot (before, it wrote a one-off there, a second event when the series did hold it): give it up with `discard_id`.",
                        "one reading, as before, when that series cannot be read or the `/RID=` is only in the external identifier."], in: "README.md")
        try assertOnce(["**沒有時區的系列（#539，沒有修好）：**",
                        "整個系列刪除的 undo 對每一種系列都把這段讀成時刻，跟 #539 之前一樣。",
                        "**這些是 `main` 本身的行為；#539 保持 open 給它們。**",
                        "undo 拒絕、什麼都不寫並保留紀錄，因為這個 server 分不出哪一種讀法才是那個場次",
                        "讀不到那個系列，或 `/RID=` 只在 external identifier 裡時，跟原本一樣只有一種讀法。"], in: "README_zh-TW.md")
        // The round-3 claims are gone (verify round 4, L1 to L26).
        try assertNone(["restores none of the series' exceptions when it recorded such an edit", "two readings are one instant, and the edit is restored as before #539",
                        "it is now recorded, which stops the restore instead"], in: "README.md")
        try assertNone(["只要記到這樣的修改，undo 就不還原這個系列的任何例外", "這個修改不會"], in: "README_zh-TW.md")
    }

    func testTheReadmesSayWhatClearTimezoneLeaves() throws {
        try assertOnce(["leaves a timed event floating, not in the system time zone (#541)",
                        "On iCloud with this Mac at `+08:00`, a whole-series time zone write on a series with such an occurrence was refused by the #503 check (#553): the check reads that time as an instant too, so it sees the occurrence off its slot only on a Mac not at offset 0 at that time, and only within the dates it lists (#506)."], in: "README.md")
        try assertOnce(["會讓計時事件變成浮動，不是改用系統時區（#541）",
                        "在 iCloud 上、這台 Mac 在 `+08:00` 時，有這種場次的系列，整個系列的時區寫入被 #503 的檢查拒絕（#553）"], in: "README_zh-TW.md")
        try assertOnce(["it reads that time as an instant, so it sees such an occurrence off its slot only on a Mac not at offset 0 at that time, and only within the dates it lists (#506). Text only."], in: "CHANGELOG.md")
    }

    func testTheReleaseGateListsTheCellsAndWhatWasNotMeasured() throws {
        try assertOnce(["## Release gate：沒有時區的系列，修改過的場次在 undo 裡的讀法（#539）",
                        "**沒有時區的系列的修改不由整個系列刪除的 undo 還原，#539 保持 open。**",
                        "PR #558 只保留四件永遠不比 `main` 差的事：",
                        "4. **MA**：",
                        "5. **C1**（verify round 4 的 C1）",
                        "8. **FR**（裁定 F 在另一個主機時區）",
                        "以上答案除了第 4、8 步的拒絕（`main` 在那裡寫出第二個事件），都是 `main` 的答案",
                        "矩陣只建模 stand-in 刪除的兩種結果；量到的第三種（stand-in 自己被留下，`main` 的 #561）沒有建模（L19）。",
                        "的提案在 #553",
                        "#509 的規則結束檢查；計畫第 5 步、mutant 11）在 #557。"], in: ".claude/rules/mcp-binary-version-testing.md")
        try assertNone(["沒有時區的還原", "裁定 E 不會被問到"], in: ".claude/rules/mcp-binary-version-testing.md")
    }

    /// #539 step 6: the documents say when a whole-series delete forecasts an undo from the rules alone.
    func testTheDocumentsSayWhenTheDeleteForecastsTheRulesAlone() throws {
        try assertOnce(["**The forecast at the delete (#539):**",
                        "checks each one's original time, read from its identifier as the undo reads it, against the slots the series' rule gives from its first slot, as the #503 check expands it.",
                        "`delete_events_batch` lists such rows under `rules_alone_on_undo`, each with its `event_id` and `undo_note`",
                        "leaving out the occurrences that the call's earlier rows delete, as the real call does, and its dry run with span \"future\" does not.",
                        "(by date range, in the row of every listed occurrence of that series)",
                        "a delete through the first edited occurrence (#428) records nothing to restore and gives its own note."], in: "README.md")
        try assertOnce(["**刪除時的預告（#539）：**",
                        "`delete_events_batch` 把這種列放在 `rules_alone_on_undo`",
                        "並且跟實際呼叫一樣，不算同一次呼叫裡較早的列刪掉的場次；span \"future\" 的 dry run 不給。"], in: "README_zh-TW.md")
        try assertOnce(["**A whole-series delete says when its undo is expected to restore the series from its rules alone** (#539)",
                        "leaving out the occurrences the call's earlier rows delete, as the real call does (PR #558 verify round 4, C3)",
                        "(step 4, its mutant 10 and device cells MB and R1; proposed on #553)",
                        "(step 5, mutant 11; #557)",
                        "for a rule the expander does not follow, more than one rule or more than 20,000 slots,",
                        "**The undo of one occurrence's delete is refused where a restored series with no time zone may already hold it** (#539, PR #558 ruling F)",
                        "**The undo of a whole-series delete is unchanged: it reads such an edit as an instant, as before #539, so on a Mac not at offset 0 it seldom matches and the series comes back from its rules alone, its edits lost (the delete forecasts it, above); #539 stays open for that.**",
                        "on a zoned series moved 16 hours later the same day, `delete_event` with span `all` carried the note and its undo restored from the rules alone too."], in: "CHANGELOG.md")
        try assertNone(["For a series with no time zone that records one whose original time has two readings"], in: "README.md")
        try assertNone(["applies none of the series' exceptions and the undo names that reason"], in: "CHANGELOG.md")
    }
}
