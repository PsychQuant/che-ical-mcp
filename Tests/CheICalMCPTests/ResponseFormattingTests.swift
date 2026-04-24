import XCTest
@testable import CheICalMCP

/// Tests for tool response serialization.
/// `formatJSON` throws on any serialization failure instead of returning
/// a placeholder — callers' catch-all must surface the error via MCP
/// `isError: true` rather than swallow it as an empty response.
final class ResponseFormattingTests: XCTestCase {

    // MARK: - Happy path

    func testFormatsSimpleDict() throws {
        let result = try formatJSON(["a": 1, "b": "two"])
        XCTAssertTrue(result.contains("\"a\""))
        XCTAssertTrue(result.contains("1"))
        XCTAssertTrue(result.contains("\"b\""))
        XCTAssertTrue(result.contains("\"two\""))
    }

    func testFormatsArrayOfDicts() throws {
        let result = try formatJSON([
            ["id": "x", "count": 1],
            ["id": "y", "count": 2]
        ])
        XCTAssertTrue(result.contains("\"x\""))
        XCTAssertTrue(result.contains("\"y\""))
    }

    func testFormatsEmptyArray() throws {
        // .prettyPrinted adds whitespace around brackets — exact shape is
        // platform-defined but must parse back to an empty array.
        let result = try formatJSON([] as [Any])
        let parsed = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [Any]
        XCTAssertEqual(parsed?.count, 0)
    }

    func testFormatsEmptyDict() throws {
        let result = try formatJSON([:] as [String: Any])
        let parsed = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.count, 0)
    }

    func testSortedKeysIsStable() throws {
        // .sortedKeys option means repeated calls produce identical output,
        // which matters for LLMs that pattern-match on exact response shape.
        let dict: [String: Any] = ["z": 1, "a": 2, "m": 3]
        let first = try formatJSON(dict)
        let second = try formatJSON(dict)
        XCTAssertEqual(first, second)
        // Keys appear in alphabetical order
        let aIdx = first.range(of: "\"a\"")!.lowerBound
        let mIdx = first.range(of: "\"m\"")!.lowerBound
        let zIdx = first.range(of: "\"z\"")!.lowerBound
        XCTAssertTrue(aIdx < mIdx)
        XCTAssertTrue(mIdx < zIdx)
    }

    func testProducesValidUTF8() throws {
        let result = try formatJSON(["unicode": "日本語 🎉 émoji"])
        let roundtrip = result.data(using: .utf8)
        XCTAssertNotNil(roundtrip, "Output must be valid UTF-8")
    }

    // MARK: - Throws on invalid input

    func testThrowsOnUnsupportedType() {
        // Raw Date is not a valid JSON type — it must have been converted to
        // String before reaching formatJSON. Without the isValidJSONObject
        // pre-check, JSONSerialization would raise NSInvalidArgumentException
        // (ObjC exception, not Swift Error) and crash the process.
        let payload: [String: Any] = ["date": Date()]
        XCTAssertThrowsError(try formatJSON(payload)) { error in
            guard case ToolError.invalidParameter = error else {
                XCTFail("Expected ToolError.invalidParameter, got \(error)")
                return
            }
        }
    }

    func testThrowsOnNaN() {
        let payload: [String: Any] = ["value": Double.nan]
        XCTAssertThrowsError(try formatJSON(payload)) { error in
            guard case ToolError.invalidParameter = error else {
                XCTFail("Expected ToolError.invalidParameter, got \(error)")
                return
            }
        }
    }

    func testThrowsOnInfinity() {
        let payload: [String: Any] = ["value": Double.infinity]
        XCTAssertThrowsError(try formatJSON(payload)) { error in
            guard case ToolError.invalidParameter = error else {
                XCTFail("Expected ToolError.invalidParameter, got \(error)")
                return
            }
        }
    }

    // MARK: - actionResult envelope

    func testActionResultWrapsDict() throws {
        let result = try actionResult([
            "action": "created",
            "id": "abc-123"
        ])
        XCTAssertTrue(result.contains("\"action\""))
        XCTAssertTrue(result.contains("\"created\""))
        XCTAssertTrue(result.contains("\"abc-123\""))
    }

    func testActionResultPropagatesFormatJSONError() {
        XCTAssertThrowsError(try actionResult(["date": Date()])) { error in
            guard case ToolError.invalidParameter = error else {
                XCTFail("Expected ToolError.invalidParameter, got \(error)")
                return
            }
        }
    }
}
