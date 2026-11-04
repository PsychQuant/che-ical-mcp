import CheMCPKit
import Darwin
import Foundation

/// The canonical path of the binary this process runs (#360).
///
/// The kernel's answer (`proc_pidpath`, the same lookup `SelfDisclaim` uses to re-exec) comes
/// first, canonicalized with `realpath(3)` so it matches what the argv[0] resolution gave for
/// an absolute or symlinked argv[0] (the drift detector compares it with TCC.db entries).
/// argv[0] is only the fallback when the kernel returns nothing: a bare argv[0] (`CheICalMCP`
/// started through `PATH`) has no slash, so `realpath` resolves it against the current
/// directory and can name a file there that never ran.
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
        return BinaryPathResolver.resolveArgv0(argv0)
    }

    static func current() -> String {
        resolve(kernelPath: LiveResponsibleProcessSource.executablePath(of: getpid()),
                argv0: CommandLine.arguments.first ?? AppVersion.name)
    }
}
