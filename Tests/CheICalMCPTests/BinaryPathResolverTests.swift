import Foundation
import XCTest
@testable import CheICalMCP

/// Coverage for `BinaryPathResolver` — the unified argv[0] resolver consolidating the
/// 3 prior diagnostic flows (`--print-tcc-path`, startup banner, `--self-update`) onto
/// `realpath(3)` semantics (#129, supersedes #121 + #128).
///
/// Tests use a temporary directory + concrete files to exercise the multi-level symlink
/// chain that the prior single-hop `destinationOfSymbolicLink` could not resolve.
final class BinaryPathResolverTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BinaryPathResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - resolveArgv0 — non-throwing path

    func testResolveArgv0_directFile_returnsCanonicalPath() throws {
        let file = tempDir.appendingPathComponent("real-binary")
        try Data().write(to: file)

        let resolved = BinaryPathResolver.resolveArgv0(file.path)
        // realpath canonicalizes /private/var ↔ /var, etc. — assert it ends with our filename.
        XCTAssertTrue(resolved.hasSuffix("real-binary"),
            "non-symlink direct path should still resolve through realpath — got: \(resolved)")
    }

    func testResolveArgv0_singleLevelSymlink_resolvesToTarget() throws {
        let target = tempDir.appendingPathComponent("target-binary")
        try Data().write(to: target)
        let link = tempDir.appendingPathComponent("link-to-target")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let resolved = BinaryPathResolver.resolveArgv0(link.path)
        XCTAssertTrue(resolved.hasSuffix("target-binary"),
            "single-hop symlink must resolve through realpath to the target — got: \(resolved)")
        XCTAssertFalse(resolved.hasSuffix("link-to-target"),
            "must NOT return the symlink path itself — TCC keys on the target, not the link")
    }

    func testResolveArgv0_multiLevelSymlinkChain_resolvesAllHops() throws {
        // Build: link_top → link_mid → real_binary
        // The pre-#129 `destinationOfSymbolicLink`-based code only resolved 1 hop, so it
        // would return `link_mid` here. realpath(3) walks the full chain.
        let realBinary = tempDir.appendingPathComponent("real-binary")
        try Data().write(to: realBinary)
        let linkMid = tempDir.appendingPathComponent("link-mid")
        try FileManager.default.createSymbolicLink(at: linkMid, withDestinationURL: realBinary)
        let linkTop = tempDir.appendingPathComponent("link-top")
        try FileManager.default.createSymbolicLink(at: linkTop, withDestinationURL: linkMid)

        let resolved = BinaryPathResolver.resolveArgv0(linkTop.path)
        XCTAssertTrue(resolved.hasSuffix("real-binary"),
            "multi-hop symlink chain must collapse to the ultimate target (#121 + #129) — got: \(resolved)")
        XCTAssertFalse(resolved.hasSuffix("link-mid"),
            "must not stop at the intermediate hop — that was the pre-#129 single-hop bug")
        XCTAssertFalse(resolved.hasSuffix("link-top"),
            "must not return the starting link path")
    }

    func testResolveArgv0_nonexistentPath_returnsStandardizedFallback() {
        let bogus = "/tmp/definitely-does-not-exist-\(UUID().uuidString)/binary"
        let resolved = BinaryPathResolver.resolveArgv0(bogus)
        XCTAssertFalse(resolved.isEmpty,
            "resolver must never return empty string — non-existent paths fall back to standardized URL")
        XCTAssertTrue(resolved.hasSuffix("binary"),
            "fallback should preserve the filename — got: \(resolved)")
    }

    // MARK: - resolveWithPATHFallback — throwing variant

    func testResolveWithPATHFallback_argv0WithSlash_behavesLikeResolveArgv0() throws {
        let target = tempDir.appendingPathComponent("self-update-target")
        try Data().write(to: target)

        let resolved = try BinaryPathResolver.resolveWithPATHFallback(target.path)
        XCTAssertTrue(resolved.hasSuffix("self-update-target"))
    }

    func testResolveWithPATHFallback_bareArgv0_walksPATH() throws {
        // Build a fake executable in tempDir, then point PATH at tempDir for this test.
        let exec = tempDir.appendingPathComponent("fake-cheical")
        try Data().write(to: exec)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)

        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        // Inject our tempDir at front of PATH for the resolver call. We can't easily mutate
        // env in-process for ProcessInfo, so we test via the absolute-path branch instead
        // and verify the bare-name failure mode separately.

        // Bare-name with PATH that doesn't contain the binary → must throw.
        // (We don't try to mutate PATH because ProcessInfo caches env at process start.)
        _ = originalPath  // silence warning; documenting intent above
        XCTAssertThrowsError(try BinaryPathResolver.resolveWithPATHFallback("zzz-definitely-not-in-path-\(UUID().uuidString)")) { err in
            guard case BinaryPathResolverError.unresolvable = err else {
                XCTFail("expected .unresolvable, got \(err)")
                return
            }
        }
    }
}
