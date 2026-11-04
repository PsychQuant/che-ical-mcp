import CheMCPKit
import Foundation
import XCTest
@testable import CheICalMCP

/// Pure-unit tests for `RunningBinaryPath` (#360): the path of the running binary comes from
/// the kernel (`proc_pidpath`), and argv[0] is only the fallback. A bare argv[0] resolved
/// with `realpath(3)` names a file in the current directory, not the binary that runs.
final class RunningBinaryPathTests: XCTestCase {

    private var tempDir: URL!
    private var savedCwd: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RunningBinaryPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedCwd = FileManager.default.currentDirectoryPath
    }

    override func tearDownWithError() throws {
        FileManager.default.changeCurrentDirectoryPath(savedCwd)
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func canonical(_ url: URL) -> String {
        BinaryPathResolver.resolveArgv0(url.path)
    }

    func testKernelPath_winsOverABareArgv0PlantedInTheCurrentDirectory() throws {
        let real = tempDir.appendingPathComponent("real/CheICalMCP")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: real)
        let work = tempDir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let planted = work.appendingPathComponent("CheICalMCP")
        try Data().write(to: planted)
        FileManager.default.changeCurrentDirectoryPath(work.path)

        let resolved = RunningBinaryPath.resolve(kernelPath: real.path, argv0: "CheICalMCP")

        XCTAssertEqual(resolved, canonical(real))
        XCTAssertNotEqual(resolved, canonical(planted))
    }

    func testNilKernelPath_fallsBackToArgv0() throws {
        let file = tempDir.appendingPathComponent("CheICalMCP")
        try Data().write(to: file)

        XCTAssertEqual(RunningBinaryPath.resolve(kernelPath: nil, argv0: file.path), canonical(file))
    }

    func testSymlinkedKernelPath_isCanonicalized() throws {
        let real = tempDir.appendingPathComponent("target")
        try Data().write(to: real)
        let link = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(RunningBinaryPath.resolve(kernelPath: link.path, argv0: "ignored"), canonical(real))
    }

    func testCurrent_isThisProcessExecutable() {
        // The test runner's own executable: the kernel names it whatever argv[0] says.
        let expected = BinaryPathResolver.resolveArgv0(
            LiveResponsibleProcessSource.executablePath(of: getpid()) ?? "")
        XCTAssertEqual(RunningBinaryPath.current(), expected)
    }
}
