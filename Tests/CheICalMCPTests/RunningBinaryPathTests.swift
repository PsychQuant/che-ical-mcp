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

    /// Verify LOW (#360): with no kernel path, a bare argv[0] is looked up on `PATH` first
    /// (the way the shell found it), not resolved against the current directory.
    func testNilKernelPath_bareArgv0_walksPATHBeforeTheCurrentDirectory() throws {
        let name = "rbp-\(UUID().uuidString.prefix(8))"
        let binDir = tempDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let onPath = binDir.appendingPathComponent(name)
        try Data().write(to: onPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onPath.path)
        let work = tempDir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data().write(to: work.appendingPathComponent(name))
        FileManager.default.changeCurrentDirectoryPath(work.path)
        let savedPATH = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", binDir.path, 1)
        defer { if let savedPATH { setenv("PATH", savedPATH, 1) } else { unsetenv("PATH") } }

        XCTAssertEqual(RunningBinaryPath.resolve(kernelPath: nil, argv0: name), canonical(onPath))
    }

    /// Round-2 verify (#360): the PATH walk skips a directory of that name and a relative
    /// PATH entry such as `.`, which would bring the current directory back.
    func testPATHWalk_skipsDirectoriesAndRelativeEntries() throws {
        let name = "rbp-\(UUID().uuidString.prefix(8))"
        let dirFirst = tempDir.appendingPathComponent("first", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dirFirst.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        let binDir = tempDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let onPath = binDir.appendingPathComponent(name)
        try Data().write(to: onPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onPath.path)
        let work = tempDir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let planted = work.appendingPathComponent(name)
        try Data().write(to: planted)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: planted.path)
        FileManager.default.changeCurrentDirectoryPath(work.path)
        let savedPATH = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", ".:\(dirFirst.path):\(binDir.path)", 1)
        defer { if let savedPATH { setenv("PATH", savedPATH, 1) } else { unsetenv("PATH") } }

        XCTAssertEqual(RunningBinaryPath.resolve(kernelPath: nil, argv0: name), canonical(onPath))
    }

    /// Round-3 verify LOW 15 (#360): a bare argv[0] that no absolute PATH entry holds is not
    /// resolved against the current directory either (a relative PATH entry such as `.` would
    /// do exactly that): it is returned as the bare name, which names no file that never ran.
    func testNilKernelPath_bareArgv0NotOnAbsolutePATH_staysBare_evenWithAPlantedFileInTheCwd() throws {
        let name = "rbp-\(UUID().uuidString.prefix(8))"
        let work = tempDir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let planted = work.appendingPathComponent(name)
        try Data().write(to: planted)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: planted.path)
        FileManager.default.changeCurrentDirectoryPath(work.path)
        let savedPATH = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", ".:bin", 1)
        defer { if let savedPATH { setenv("PATH", savedPATH, 1) } else { unsetenv("PATH") } }

        let resolved = RunningBinaryPath.resolve(kernelPath: nil, argv0: name)
        XCTAssertEqual(resolved, name)
        XCTAssertNotEqual(resolved, canonical(planted))
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
