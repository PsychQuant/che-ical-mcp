import Foundation
import XCTest
@testable import CheICalMCP

/// #540 verify round 1: every text that tells a reader what to do after a changed-after refusal
/// says that a change made back through this server is an entry of its own, which the next undo
/// takes first (E1, E3), and none still says that a person made the change, that whoever made it
/// decides (E2), or that the text names only another app or the calendar server (E4, E5). Each new
/// phrase is pinned exactly once in its document (the repo's docs-pin rule).
final class UndoChangedSourceDocsTests: XCTestCase {
    private func repoFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func once(_ phrase: String, in text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, "\(name): \(phrase)", file: file, line: line)
    }

    private func never(_ phrase: String, in text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(text.range(of: phrase, options: .caseInsensitive), "\(name): \(phrase)", file: file, line: line)
    }

    private func manifestSummary(of tool: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("mcpb/manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = manifest?["tools"] as? [[String: Any]] ?? []
        return entries.first { $0["name"] as? String == tool }?["description"] as? String ?? ""
    }

    func testTheUndoToolTextsSayWhatAChangeBackThroughThisServerNeeds() throws {
        let declared = CheICalMCPServer.defineTools().first { $0.name == "undo" }?.description ?? ""
        once("undo again once a changed field is changed back (a change made back through this server is an entry of its own above this one, which the next undo takes first: give it up with discard_id, then undo again)", in: declared, "Server.swift undo")
        let summary = try manifestSummary(of: "undo")
        once("the record stays until the change is reverted (a revert made through this server records its own entry, which has to be discarded before undoing again) or the user discards it", in: summary, "manifest undo")
        for text in [summary] { XCTAssertNil(text.range(of: "<") ?? text.range(of: ">") ?? text.range(of: "&"), "manifest display string") }
    }

    func testTheReadmesAndTheUndoHistoryDocSayTheSame() throws {
        let english = try repoFile("README.md"), chinese = try repoFile("README_zh-TW.md"), history = try repoFile("docs/UNDO_HISTORY.md")
        once("**Undo does not overwrite a change made since (#236):**", in: english, "README.md")
        once("ask the user whether to change it back and undo again, or to give up that undo with `undo` + `discard_id`. A change made back through this server is recorded as an entry of its own above that one, and the next undo takes it first: give it up with `discard_id`, then undo again (#540).", in: english, "README.md")
        once("with a text that names this server's own later operations among the possible sources (#540)", in: english, "README.md")
        once("**復原不會蓋掉之後的修改（#236）：**", in: chinese, "README_zh-TW.md")
        once("要把修改改回來再復原，或用 `undo` 加 `discard_id` 放棄這次復原，請問使用者。透過本 server 改回來的修改會在那筆紀錄上面另記一筆，下一次復原會先處理它：先用 `discard_id` 放棄它，再復原（#540）。", in: chinese, "README_zh-TW.md")
        once("文字把本 server 之後的操作列為可能的來源之一（#540）", in: chinese, "README_zh-TW.md")
        once("A change made back through this server is recorded as an entry of its own above that one, and the next undo takes it first: give it up with `discard_id`, then undo again.", in: history, "docs/UNDO_HISTORY.md")
        for (name, text) in [("README.md", english), ("docs/UNDO_HISTORY.md", history)] {
            never("whoever made the change", in: text, name)
            never("a change a person made", in: text, name)
            never("still names another app or the calendar server", in: text, name)
        }
        never("由做出修改的人決定", in: chinese, "README_zh-TW.md")
        never("之後有人做的修改", in: chinese, "README_zh-TW.md")
        never("文字仍說是別的 app 或行事曆伺服器改的", in: chinese, "README_zh-TW.md")
    }

    /// E5: the #538 and #484 entries of [Unreleased] and the #538 requirement stated the old text as current.
    func testTheChangelogAndTheSpecNoLongerDescribeTheOldTextAsCurrent() throws {
        let changelog = try repoFile("CHANGELOG.md")
        let unreleased = changelog.components(separatedBy: "\n## [1.23.0]").first ?? changelog
        never("with the changed-after text that names another app or the calendar server", in: unreleased, "CHANGELOG [Unreleased]")
        never("which says the change was made in another app or by the calendar server", in: unreleased, "CHANGELOG [Unreleased]")
        once("with the changed-after text, which since #540 names this server's own later operations among the possible sources", in: unreleased, "CHANGELOG [Unreleased]")
        let spec = try repoFile("openspec/specs/undo-history-discard/spec.md")
        never("which names another app or the calendar server (#540)", in: spec, "undo-history-discard spec")
        once("with the comparison's text, which names this server's own later operations among the possible sources (#540)", in: spec, "undo-history-discard spec")
        once("A change made back through this server is recorded as an entry of its own above the refused one, and the next undo takes that entry first", in: spec, "undo-history-discard spec")
    }
}
