import CheMCPKit
import Darwin
import Foundation

/// The canonical path of the binary this process runs (#360).
///
/// The kernel's answer (`proc_pidpath`, the same lookup `SelfDisclaim` uses to re-exec) comes
/// first, canonicalized with `realpath(3)` so it matches what the argv[0] resolution gave for
/// an absolute or symlinked argv[0] (the drift detector compares it with TCC.db entries).
/// argv[0] is only the fallback when the kernel returns nothing: a bare argv[0] (`CheICalMCP`
/// started through `PATH`) has no slash, so `realpath` would resolve it against the current
/// directory and could name a file there that never ran; the fallback walks the absolute
/// `PATH` entries (`pathLookup`) and, when none holds the name, keeps the bare name.
///
/// Every place that shows or acts on "this binary" uses it: the access-denied `--setup` hint,
/// the `.mcpb` install check, `--print-tcc-path`, the startup banner and the `--setup` window.
/// `--self-update` keeps `BinaryPathResolver.resolveWithPATHFallback`, which walks `PATH`.
enum RunningBinaryPath {
    static func resolve(kernelPath: String?, argv0: String) -> String {
        if let kernelPath, !kernelPath.isEmpty {
            // An absolute path: resolveArgv0 is realpath(3) with a standardized fallback.
            return BinaryPathResolver.resolveArgv0(kernelPath)
        }
        // A bare argv[0] came from a PATH lookup: repeat it over the absolute entries only.
        // When none holds it, keep the bare name: realpath would resolve it against the current
        // directory, which is what a relative PATH entry such as `.` does too, and could name a
        // file there that never ran (#360 verify, round 3 LOW 15).
        if !argv0.isEmpty, !argv0.contains("/") {
            return pathLookup(argv0) ?? argv0
        }
        return BinaryPathResolver.resolveArgv0(argv0)
    }

    /// The first absolute `PATH` entry holding a regular, executable file named `name`,
    /// canonicalized. Relative entries (`.`, empty, `bin`) are skipped because they resolve
    /// against the current directory, and so is a directory of that name (round-2 verify:
    /// `resolveWithPATHFallback` accepted both).
    static func pathLookup(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        guard let path, !name.isEmpty else { return nil }
        let fm = FileManager.default
        for entry in path.split(separator: ":", omittingEmptySubsequences: true) where entry.hasPrefix("/") {
            let candidate = "\(entry)/\(name)"
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: candidate) else { continue }
            return BinaryPathResolver.resolveArgv0(candidate)
        }
        return nil
    }

    static func current() -> String {
        resolve(kernelPath: LiveResponsibleProcessSource.executablePath(of: getpid()),
                argv0: CommandLine.arguments.first ?? AppVersion.name)
    }
}
