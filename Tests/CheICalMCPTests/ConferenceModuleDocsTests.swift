import XCTest

/// #351 (PR #498 round 5): hand-built adoption is out of v1. The conference contract and its spec are
/// text a model follows, so these pins keep each rule in its document: each phrase must occur exactly
/// once, so removing the rule removes the only copy.
final class ConferenceModuleDocsTests: XCTestCase {
    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("package root not found")
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: try repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    private let contract = "plugin/rules/modules/conference.md"
    private let spec = "openspec/changes/add-conference-module/specs/conference-module/spec.md"
    private let design = "openspec/changes/add-conference-module/design.md"

    private var pins: [(String, String, String)] {
        [
            (contract, "**A hand-built event is never adopted, renamed or written**", "no adoption in v1"),
            (contract, "\"hand-built event <event> found; create the item anyway?\"", "one yes/no row per item"),
            (contract, "**Create is never offered where `create_event` would skip or duplicate**", "the duplicate guard"),
            (contract, "a listed all-day event is titled with the official name exactly", "the umbrella guard is narrow (r5 LOW 15)"),
            (contract, "**An event is left out only when every item it may be already has an event**", "the take rule, negative form (r5 #1 #4)"),
            (contract, "**When the chosen set turns out not to be this program's**", "step 2 then builds in the routed calendar (r5 #6)"),
            (contract, "is another conference` when the chosen set turned out not to be this program's, step 2)", "report line 1 says so (r5 #6)"),
            (contract, "**Use** can be chosen for one set only", "step 2 uses one set (r5 LOW 11)"),
            (contract, "When the question names only one set, a yes names that set.", "rename yes with one set (r5 LOW 8)"),
            (contract, "`Umbrella: declined (hand-built row answered no)`", "a declined umbrella is reported (r5 LOW 10)"),
            (contract, "An event whose notes hold the pair more than once is not a module event either", "a double-pair event is listed (r5 LOW 16)"),
            (spec, "The module SHALL NOT adopt, rename or write a hand-built event", "no adoption (spec)"),
            (spec, "the new set SHALL be built in the routed calendar", "step 2 fallback (spec)"),
            (spec, "#### Scenario: The chosen set is another conference", "step 2 fallback scenario"),
            (spec, "#### Scenario: A hand-built all-day event of one day of the conference", "umbrella guard scenario"),
            (design, "### 採納從 v1 拿掉（PR #498 第 5 輪，2026-11-09）", "the deferral is recorded"),
        ]
    }

    func testEveryRuleIsInItsDocumentOnce() throws {
        var texts: [String: String] = [:]
        for (document, phrase, item) in pins {
            if texts[document] == nil { texts[document] = try read(document) }
            let count = texts[document]!.components(separatedBy: phrase).count - 1
            XCTAssertEqual(count, 1, "\(document) holds the rule for \(item) \(count) times, not once (\(phrase))")
        }
    }

    /// The adoption answers, rows and paragraph are gone from the contract and the spec.
    func testAdoptionIsGone() throws {
        let contractText = try read(contract)
        for gone in ["**Adoption** writes", "**Name-only row**", "**Row naming several events**", "create the item as new",
                     "adopted N", "an adopt answer"] {
            XCTAssertFalse(contractText.contains(gone), "\(contract): \(gone)")
        }
        let specText = try read(spec)
        for gone in ["adoption SHALL write the marker lines", "until the user agrees to adopt it", "Declining an adoption SHALL NOT create",
                     "#### Scenario: A hand-built umbrella with an inclusive end is adopted"] {
            XCTAssertFalse(specText.contains(gone), "\(spec): \(gone)")
        }
    }
}
