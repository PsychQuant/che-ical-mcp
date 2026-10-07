import XCTest

/// The source-pin reader itself (PR #278 verify round 2, findings 12/16/20/25/26): a pin must see
/// exactly the function it names, and never text in a comment or a string.
final class SourcePinsTests: XCTestCase {
    private let source = """
    struct S {
        func first() {
            // eventStore.remove( in a comment
            let text = "eventStore.remove( in a string, with a } brace and \\("nested \\(1) }") too"
            if true { work() }
        }
        private func second() {
            eventStore.remove(x)
        }
        func third() {}
    }
    """

    func testABodyEndsAtItsOwnClosingBrace() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func first()", in: source))
        XCTAssertTrue(body.contains("work()"))
        XCTAssertFalse(body.contains("second"), "the next declaration is not part of it, whichever kind it is")
        XCTAssertTrue(body.hasSuffix("}"))
    }

    func testCommentsAndStringsNeverSatisfyAPin() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func first()", in: source))
        XCTAssertTrue(SourcePins.ranges(of: "eventStore.remove(", in: body).isEmpty, body)
        let second = try XCTUnwrap(SourcePins.body(of: "func second()", in: source))
        XCTAssertEqual(SourcePins.ranges(of: "eventStore.remove(", in: second).count, 1)
    }

    func testADeclarationInACommentIsNotFound() {
        XCTAssertNil(SourcePins.body(of: "func fourth()", in: "// func fourth() { x }\nfunc other() {}"))
    }

    /// A whole file's code, for pins that count a call across files (PR #282's runner-caller pin).
    func testTheCodeOfAWholeFileHasNoCommentsOrStrings() {
        let code = SourcePins.code("let a = \"run( in // a string\" // run( in a comment\nrun(x)\n/* run( */")
        XCTAssertEqual(SourcePins.ranges(of: "run(", in: code).count, 1, code)
        XCTAssertEqual(code.split(separator: "\n", omittingEmptySubsequences: false).count, 3, "newlines stay")
    }

    func testPatternsTolerateSpacing() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func first()", in: "func first() {\n  self.value   =  a ?? b.value\n}"))
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"self\.value\s*=\s*a\s*\?\?\s*b\.value"#, in: body).count, 1)
    }
}
