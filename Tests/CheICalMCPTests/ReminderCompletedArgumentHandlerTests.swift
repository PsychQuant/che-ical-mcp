import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// Records what the read handlers hand to the source, so the `null` = no-filter
/// and "rejected before any read" halves of #205 can actually fail.
private actor RecordingReadFake: ReminderReadSource {
    var calls = 0
    var received: [Bool?] = []
    func listReminderSnapshots(completed: Bool?, calendarName: String?, calendarSource: String?) async throws -> [ReminderReadSnapshot] {
        calls += 1; received.append(completed); return []
    }
    func searchReminderSnapshots(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?) async throws -> [ReminderReadSnapshot] {
        calls += 1; received.append(completed); return []
    }
}

final class ReminderCompletedArgumentHandlerTests: XCTestCase {
    private let tools: [(String, [String: Value])] = [("list_reminders", [:]), ("search_reminders", ["keyword": .string("x")])]

    func testListAndSearchRejectNonBooleanCompletedBeforeAnyRead() async throws {
        for (tool, extra) in tools {
            for bad in [Value.string("true"), .string("false"), .int(1), .double(0)] {
                let fake = RecordingReadFake()
                let server = try await TestServer.make(reminderReadSource: fake)
                var args = extra; args["completed"] = bad
                do {
                    _ = try await server.executeToolCall(name: tool, arguments: args)
                    XCTFail("\(tool) must reject non-boolean completed \(bad)")
                } catch let error as ToolError {
                    XCTAssertTrue("\(error)".contains("completed must be a boolean"), "\(tool): \(error)")
                }
                let calls = await fake.calls
                XCTAssertEqual(calls, 0, "\(tool): must be rejected before any read")
            }
        }
    }

    func testNullCompletedMeansNoFilterOnReadTools() async throws {
        for (tool, extra) in tools {
            let fake = RecordingReadFake()
            let server = try await TestServer.make(reminderReadSource: fake)
            var args = extra; args["completed"] = .null
            _ = try await server.executeToolCall(name: tool, arguments: args)
            let received = await fake.received
            XCTAssertEqual(received.count, 1, tool)
            XCTAssertNil(received.first ?? nil, "\(tool): null must reach the source as no filter")
        }
    }

    func testListRejectsNonBooleanCompletedEvenWhenFilterIsPresent() async throws {
        // `filter` takes priority over `completed`, but the type contract is unconditional.
        let fake = RecordingReadFake()
        let server = try await TestServer.make(reminderReadSource: fake)
        do {
            _ = try await server.executeToolCall(name: "list_reminders", arguments: ["filter": .string("all"), "completed": .string("false")])
            XCTFail("list_reminders must reject a non-boolean completed even when filter is present")
        } catch let error as ToolError {
            XCTAssertTrue("\(error)".contains("completed must be a boolean"), "\(error)")
        }
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }
}
