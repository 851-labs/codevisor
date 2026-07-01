import AppKit
import Foundation
import HerdManCore

/// Everything needed to launch a terminal surface. The terminal renderer is local
/// Ghostty, but the command always runs the HerdMan proxy, which connects to the
/// server that owns the session.
struct TerminalLaunchDescriptor: Equatable {
    let sessionId: UUID
    let machine: HerdManMachine
    let workingDirectory: URL
    let command: String

    static func make(session: ChatSession, workspace: Workspace, machine: HerdManMachine) -> TerminalLaunchDescriptor {
        TerminalLaunchDescriptor(
            sessionId: session.id,
            machine: machine,
            workingDirectory: workspace.folderURL,
            command: TerminalProxyCommand.command(
                server: machine.baseURL,
                sessionId: session.id,
                cwd: workspace.folderURL.path
            )
        )
    }
}

enum TerminalProxyCommand {
    nonisolated static func command(server: URL, sessionId: UUID, cwd: String) -> String {
        let args = [
            "--server", server.absoluteString,
            "--session-id", sessionId.uuidString,
            "--cwd", cwd
        ]
        let executable = proxyExecutable()
        return ([executable.command] + executable.prefixArgs + args)
            .map(shellQuote)
            .joined(separator: " ")
    }

    nonisolated private static func proxyExecutable() -> (command: String, prefixArgs: [String]) {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["HERDMAN_TERMINAL_PROXY"], !override.isEmpty {
            return (override, [])
        }
        if let entrypoint = proxyEntrypoint() {
            let node = LocalHerdManServer.defaultNodeExecutable()
            let prefix = node.lastPathComponent == "env" ? ["node", entrypoint.path] : [entrypoint.path]
            return (node.path, prefix)
        }
        return ("/usr/bin/env", ["herdman-terminal-proxy"])
    }

    nonisolated private static func proxyEntrypoint() -> URL? {
        let bundledCandidates = [
            Bundle.main.url(forResource: "terminal-proxy", withExtension: "js", subdirectory: "server"),
            Bundle.main.url(forResource: "terminal-proxy", withExtension: "js", subdirectory: "Server"),
            Bundle.main.url(forResource: "herdman-terminal-proxy", withExtension: "js")
        ].compactMap { $0 }
        if let bundled = bundledCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return bundled
        }

        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = directory.appendingPathComponent("apps/server/dist/terminal-proxy.js")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// A live terminal surface: an `NSView` that renders an interactive shell scoped
/// to a working directory. Implemented either by libghostty (when `GhosttyKit`
/// is linked) or by a placeholder (so the app builds and the UI is fully
/// functional before the framework is available).
@MainActor
protocol TerminalSurface: AnyObject {
    /// The view to embed in the terminal panel. The surface owns it for its
    /// whole lifetime so terminal state survives panel close + navigation.
    var nsView: NSView { get }
    /// Routes keyboard focus into (or out of) the terminal.
    func setFocused(_ focused: Bool)
    /// Tears down the shell/PTY and releases resources.
    func terminate()
}

/// Creates terminal surfaces. One factory is selected at launch depending on
/// whether libghostty is linked.
@MainActor
protocol TerminalSurfaceFactory {
    func makeSurface(descriptor: TerminalLaunchDescriptor) -> any TerminalSurface
}

/// Selects the terminal backend. Uses libghostty when `GhosttyKit` is linked,
/// otherwise a buildable placeholder. The real terminal drops in unchanged via
/// the `TerminalSurface` protocol once the framework is present.
@MainActor
enum TerminalRuntime {
    static let factory: any TerminalSurfaceFactory = {
        // SwiftUI previews use the placeholder so they never spawn a real shell
        // (which would fork inside the fork-hostile preview harness).
        if AppPreview.isRunning { return PlaceholderTerminalFactory() }
        #if canImport(GhosttyKit)
        return GhosttyTerminalFactory.shared
        #else
        return PlaceholderTerminalFactory()
        #endif
    }()

    /// Whether a real terminal backend is available. The UI uses this to show a
    /// hint in the placeholder state.
    static var isLive: Bool {
        #if canImport(GhosttyKit)
        return true
        #else
        return false
        #endif
    }

    /// Eagerly initializes the terminal backend at app launch, in a clean
    /// context (not inside a SwiftUI update / event handler). This completes the
    /// libghostty runtime's `dispatch_once`-backed setup up front so opening the
    /// terminal later never re-enters an in-progress `once` (which traps with
    /// `_dispatch_once_wait` / EXC_BREAKPOINT).
    static func prewarm() {
        #if canImport(GhosttyKit)
        _ = GhosttyRuntime.shared.app
        #endif
    }
}
