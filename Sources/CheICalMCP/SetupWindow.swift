import Foundation
@preconcurrency import EventKit
#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
#endif

/// Per-entity display state shown in the SetupWindow. Derived from
/// `EKAuthorizationStatus` (plus an `.error` state when a grant request throws).
/// Pure value so the mapping is unit-testable without AppKit/SwiftUI (#164).
enum SetupEntityState: Equatable {
    case granted
    case writeOnly
    case denied
    case notDetermined
    case error(String)

    /// Map a raw TCC status into a display state.
    static func from(_ status: EKAuthorizationStatus) -> SetupEntityState {
        switch status {
        case .fullAccess: return .granted
        case .writeOnly: return .writeOnly
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    var isGranted: Bool { self == .granted }

    /// Short human-readable summary shown under the entity name.
    var summary: String {
        switch self {
        case .granted: return "full access granted"
        case .writeOnly: return "write-only (partial — upgrade to full access in System Settings)"
        case .denied: return "denied — use Open System Settings below to grant"
        case .notDetermined: return "not yet determined — click Grant"
        case .error(let m): return "error — \(m)"
        }
    }
}

#if canImport(AppKit) && canImport(SwiftUI)
/// The `--setup` GUI: a launch-on-demand window showing live Calendar / Reminders
/// status, per-entity Grant buttons that fire EventKit's `requestFullAccess*` (the
/// system dialog), the resolved binary path being authorized, and Copy / Open-Settings
/// fallbacks. Re-checks on a timer so it flips to Ready the instant access is granted.
///
/// Mirrors che-apple-mail-mcp's `SetupWindow` (che-apple-mail-mcp#213), but richer:
/// EventKit has a request API (FDA does not), so this can grant directly rather than
/// only sending the user to System Settings. Gated behind `--setup` (see `SetupRunner`):
/// AppKit/SwiftUI are load-time deps, but this runloop only *starts* under interactive
/// `--setup` — the stdio MCP path never enters it. (#164, follow-up to #163)
@MainActor
final class SetupModel: ObservableObject {
    @Published var calendar: SetupEntityState
    @Published var reminders: SetupEntityState

    /// Absolute path of the binary being authorized — surfaced so `.mcpb` users can see
    /// WHICH (buried) binary the grant applies to.
    let binaryPath: String

    private let probe: AuthorizationStatusSource
    private var timer: Timer?

    init(
        probe: AuthorizationStatusSource = LiveAuthorizationStatusSource(),
        binaryPath: String = BinaryPathResolver.resolveArgv0(CommandLine.arguments.first ?? AppVersion.name)
    ) {
        self.probe = probe
        self.binaryPath = binaryPath
        self.calendar = SetupEntityState.from(probe.authorizationStatus(for: .event))
        self.reminders = SetupEntityState.from(probe.authorizationStatus(for: .reminder))
    }

    var isReady: Bool { calendar.isGranted && reminders.isGranted }

    /// Re-read both statuses from TCC (cheap, never prompts).
    func refresh() {
        calendar = SetupEntityState.from(probe.authorizationStatus(for: .event))
        reminders = SetupEntityState.from(probe.authorizationStatus(for: .reminder))
    }

    /// Start live polling so the window flips to Ready the moment the user grants.
    /// Idempotent: a view re-appear (miniaturize/deminiaturize) must not leak a second
    /// repeating timer — mirrors che-apple-mail-mcp's SetupModel.
    func start() {
        stop()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether a repeating poll timer is currently scheduled (test-visibility for the
    /// start() idempotency guard).
    var isPolling: Bool { timer != nil }

    /// Request full access for one entity. On `.notDetermined` this presents the system
    /// dialog; after a denial the framework no longer re-prompts (use Open System Settings).
    /// Framework error text is sanitized at the boundary (#146).
    func grant(_ entity: EKEntityType) async {
        do {
            _ = try await probe.requestFullAccess(for: entity)
        } catch {
            let safe = EventKitErrorSanitizer.escapeForStderr(error.localizedDescription)
            set(entity, .error(safe))
            return
        }
        // Re-read the authoritative status rather than trusting the bool.
        refresh()
    }

    private func set(_ entity: EKEntityType, _ state: SetupEntityState) {
        switch entity {
        case .event: calendar = state
        case .reminder: reminders = state
        @unknown default: break
        }
    }

    /// Deep-link to the System Settings privacy pane for an entity (denial fallback).
    func openSettings(_ entity: EKEntityType) {
        let pane = entity == .reminder
            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    func copyBinaryPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(binaryPath, forType: .string)
    }
}

@MainActor
final class SetupAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: SetupView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "CheICalMCP — Calendar & Reminders Setup"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 480, height: 460))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SetupView: View {
    @StateObject private var model = SetupModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Calendar & Reminders access setup").font(.title2).bold()

            entityRow("Calendar", state: model.calendar, entity: .event)
            entityRow("Reminders", state: model.reminders, entity: .reminder)

            Divider()

            Text("You are authorizing THIS binary:")
                .font(.caption).foregroundColor(.secondary)
            Text(model.binaryPath)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") { model.openSettings(.event) }
                Button("Copy binary path") { model.copyBinaryPath() }
            }

            Spacer()

            if model.isReady {
                Text("✅ Both granted — Calendar & Reminders ready.")
                    .foregroundColor(.green).bold()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 430, alignment: .topLeading)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private func entityRow(_ name: String, state: SetupEntityState, entity: EKEntityType) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(state.isGranted ? Color.green : (state == .notDetermined ? Color.gray : Color.red))
                .frame(width: 12, height: 12)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).bold()
                Text(state.summary).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !state.isGranted {
                Button("Grant \(name) access") {
                    Task { await model.grant(entity) }
                }
            }
        }
    }
}
#endif

/// Entry point for the interactive `--setup` window. On AppKit+SwiftUI platforms this
/// runs a foreground `NSApplication` hosting `SetupView`; elsewhere it degrades to the
/// headless `SetupRunner.requestBoth` flow. Never returns.
enum SetupWindow {
    @MainActor
    static func run() -> Never {
        #if canImport(AppKit) && canImport(SwiftUI)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)            // foreground app -> TCC dialogs can attach
        let delegate = SetupAppDelegate()
        app.delegate = delegate
        app.run()                                    // window-driven; exits when the window closes
        exit(0)                                      // unreachable — satisfies Never
        #else
        let sema = DispatchSemaphore(value: 0)
        var bad = false
        Task { @MainActor in bad = await SetupRunner.requestBoth(nonInteractive: false); sema.signal() }
        sema.wait()
        SetupRunner.printGuidanceIfNeeded(bad)
        exit(bad ? 1 : 0)
        #endif
    }
}
