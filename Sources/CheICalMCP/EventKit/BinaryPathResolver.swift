import Darwin
import Foundation

/// Unified argv[0] resolver for diagnostic + self-update entry points.
///
/// Background (#129, #121, #128): three diagnostic flows previously each rolled their own
/// path-resolution strategy — `--print-tcc-path` and the startup banner used Foundation
/// `destinationOfSymbolicLink` (single-hop, swallowed non-symlink errors), while
/// `--self-update` used POSIX `realpath(3)` (multi-hop, with `$PATH` walk for bare argv[0]).
/// Users saw three different path strings for the same binary depending on which
/// diagnostic they invoked, and multi-level symlink chains (e.g.
/// `~/bin/CheICalMCP → ../share/che-ical-mcp/current → ../che-ical-mcp-0.3.4/CheICalMCP`)
/// produced false-positive drift signals because the banner reported the intermediate hop
/// while TCC.db keyed on the final destination.
///
/// This helper consolidates onto `realpath(3)` (resolves the full chain to canonical
/// absolute path) with a Foundation fallback for the edge case where the file is missing
/// or `realpath` fails. Single source of truth; all three call sites converge on the same
/// string for the same binary.
enum BinaryPathResolver {
    /// Resolve `argv[0]` to its canonical absolute path. Never throws; always returns a
    /// non-empty string (worst case the input string, standardized).
    ///
    /// Resolution order:
    /// 1. POSIX `realpath(3)` — walks multi-level symlinks, returns canonical absolute path.
    ///    Fails (returns `nil`) only when the path doesn't exist or permission is denied.
    /// 2. Foundation `destinationOfSymbolicLink` (single-hop) + recursive `realpath` on the
    ///    target — handles the case where intermediate permission breaks `realpath` but the
    ///    direct symlink target is readable.
    /// 3. `URL(fileURLWithPath:).standardizedFileURL.path` — raw fallback for nonexistent
    ///    paths (returned as-is, standardized).
    static func resolveArgv0(_ argv0: String) -> String {
        if let resolved = realpathOrNil(argv0) {
            return resolved
        }
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: argv0) {
            if let resolvedDest = realpathOrNil(dest) {
                return resolvedDest
            }
            return URL(fileURLWithPath: dest).standardizedFileURL.path
        }
        return URL(fileURLWithPath: argv0).standardizedFileURL.path
    }

    /// Throwing variant for `--self-update` style flows that require a resolvable canonical
    /// path *and* support PATH-resolved invocations (`CheICalMCP --self-update` where the
    /// shell looked up `CheICalMCP` in `$PATH`, leaving `argv[0]` as the bare name).
    ///
    /// - If `argv0` contains a slash → behaves like `resolveArgv0`.
    /// - If `argv0` is bare → walks `$PATH` looking for the first executable named `argv0`,
    ///   then resolves that candidate via `realpath`.
    /// - Throws `BinaryPathResolverError.unresolvable` if PATH is unset, or no PATH entry
    ///   yields an executable file matching `argv0`.
    static func resolveWithPATHFallback(_ argv0: String) throws -> String {
        if argv0.contains("/") {
            return resolveArgv0(argv0)
        }
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else {
            throw BinaryPathResolverError.unresolvable
        }
        let fm = FileManager.default
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(argv0)"
            if fm.isExecutableFile(atPath: candidate) {
                return resolveArgv0(candidate)
            }
        }
        throw BinaryPathResolverError.unresolvable
    }

    private static func realpathOrNil(_ path: String) -> String? {
        path.withCString { cPath in
            guard let resolved = realpath(cPath, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}

enum BinaryPathResolverError: Error, LocalizedError {
    case unresolvable

    var errorDescription: String? {
        switch self {
        case .unresolvable:
            return "Could not resolve binary path — argv[0] is bare and no $PATH entry yields an executable match."
        }
    }
}
