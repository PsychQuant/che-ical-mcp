import Foundation

/// #600: under XCTest, the live EventKit manager (`EventKitManager.shared`) and the process-wide undo
/// history (`CalendarUndoManager.shared`) stop the test process at first use, unless the test opted in
/// with `LiveStoreGuard.allowingLiveStore { ... }`. Each use is checked, not only the first, so a test
/// that runs after another one opted in is checked too.
///
/// Tests build the server with doubles for every source and an undo history of their own
/// (`TestServer.make`); a test that leaves one source at its default, or the undo history at
/// `.shared`, reaches `shared` while the server is built and stops here with the call stack. This
/// replaces text pins on how a test spells its server: any spelling that reaches `shared` stops.
///
/// Only DEBUG builds carry the check (the release body is empty), and it is active only when the
/// XCTest framework is loaded in this process (`XCTestCase` resolves). It does not read the
/// `XCTestConfigurationFilePath` environment variable: a binary a test spawns inherits the
/// environment but does not load XCTest, and its server must start as it does for a user.
enum LiveStoreGuard {
    #if DEBUG
    /// Whether this process runs tests: `XCTestCase` resolves only when XCTest is loaded.
    static let isUnderXCTest: Bool = NSClassFromString("XCTestCase") != nil

    @TaskLocal static var liveStoreAllowed = false

    /// Runs `body` with the live manager and the shared undo history allowed. A test that needs the
    /// developer's real store must say so here; no test in the suite does.
    static func allowingLiveStore<T>(_ body: () async throws -> T) async rethrows -> T {
        try await $liveStoreAllowed.withValue(true) { try await body() }
    }

    /// The message `check` stops with, or nil when `what` may be used here: outside XCTest, or inside
    /// `allowingLiveStore`.
    static func violation(_ what: StaticString) -> String? {
        guard isUnderXCTest, !liveStoreAllowed else { return nil }
        return "#600 LiveStoreGuard: \(what) was used under XCTest. Build the server with TestServer.make "
            + "(every source a double, an undo history of its own), or wrap the test in "
            + "LiveStoreGuard.allowingLiveStore if it must reach the real store."
    }

    /// Stops the process, with the call stack, when `what` is used under XCTest outside
    /// `allowingLiveStore`.
    static func check(_ what: StaticString) {
        guard let message = violation(what) else { return }
        let stack = Thread.callStackSymbols.prefix(24).joined(separator: "\n")
        FileHandle.standardError.write(Data((message + "\n" + stack + "\n").utf8))
        preconditionFailure(message)
    }
    #else
    @inline(__always) static func check(_ what: StaticString) {}
    #endif
}
