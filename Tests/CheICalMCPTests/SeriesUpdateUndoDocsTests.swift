import Foundation
import XCTest
@testable import CheICalMCP

/// #263 verify r2: the closed list of the restorable whole-series update is restated in every public
/// text. Each text must hold each exclusion phrase exactly once (a `contains()` pin survives a
/// restatement that drifted, the repo's docs-pin rule), so the next narrowing cannot change one text
/// and leave the others. The Swift constants are the source; Server.swift interpolates them.
final class SeriesUpdateUndoDocsTests: XCTestCase {
    private func repoFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private static let english = [
        "passed only event_id, span and title, notes or location",
        "with span all through the series' own identifier",
        "on an iCloud calendar",
        "starts and ends within the dates undo lists its occurrences over",
        "never a series with no end",
        "first occurrence was not edited or deleted on its own",
        "no location written over a place with coordinates",
        "the same occurrences edited or deleted on their own listed before and after the save",
        "in each field it wrote, either followed the update",
        "nothing else of it changed",
        "inferred across the three fields",
        "unless the written value equals the old one",
        "measured only on a series that had not started",
        "moved more than a year outside the listed dates",
    ]

    private static let chinese = [
        "只傳了 event_id、span 與 title、notes 或 location",
        "經系列自己的 id、span all",
        "在 iCloud 日曆上",
        "開始與結束都在復原列出場次的日期內",
        "不設結束的系列一定不算",
        "第一個場次沒有單獨修改或刪除過",
        "沒有在有座標的地點上寫 location",
        "存檔前後列出的單獨修改或刪除過的場次相同",
        "在寫入的每個欄位上，不是跟著改",
        "其他欄位都沒變",
        "依量到的結果推到三個欄位",
        "除非寫入的值等於舊值",
        "只在還沒開始的系列量過",
        "移到列出日期一年以外",
    ]

    private func assertEachOnce(_ phrases: [String], in text: String, _ name: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        for phrase in phrases {
            XCTAssertEqual(text.components(separatedBy: phrase).count - 1, 1, "\(name): \(phrase)", file: file, line: line)
        }
    }

    func testTheSwiftConstantsHoldEveryPhraseOnce() {
        assertEachOnce(Self.english, in: SeriesUpdateUndo.restorableShape + " " + SeriesUpdateUndo.restorableShapeNotes, "constants")
    }

    func testEveryEnglishTextStatesTheListOnce() throws {
        for file in ["README.md", "CHANGELOG.md", "docs/UNDO_HISTORY.md", "openspec/specs/undo-history-discard/spec.md"] {
            assertEachOnce(Self.english, in: try repoFile(file), file)
        }
    }

    func testBothManifestEntriesStateTheListOnce() throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(try repoFile("mcpb/manifest.json").utf8)) as? [String: Any]
        let tools = try XCTUnwrap(manifest?["tools"] as? [[String: Any]])
        for name in ["undo", "update_event"] {
            let description = try XCTUnwrap(tools.first { $0["name"] as? String == name }?["description"] as? String, name)
            assertEachOnce(Self.english, in: description, "manifest \(name)")
        }
    }

    func testTheChineseReadmeStatesTheListOnce() throws {
        assertEachOnce(Self.chinese, in: try repoFile("README_zh-TW.md"), "README_zh-TW.md")
    }

    /// Server.swift states the list through the constants, not a copy.
    func testServerInterpolatesTheConstants() throws {
        let server = try repoFile("Sources/CheICalMCP/Server.swift")
        XCTAssertEqual(server.components(separatedBy: "\\(SeriesUpdateUndo.restorableShape)").count - 1, 2, "update_event and undo")
        XCTAssertEqual(server.components(separatedBy: "\\(SeriesUpdateUndo.restorableShapeNotes)").count - 1, 2)
        XCTAssertEqual(server.components(separatedBy: Self.english[0]).count - 1, 0, "no literal copy")
    }
}
