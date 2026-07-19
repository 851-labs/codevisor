import AppKit
import Foundation
import CodevisorCore

/// Everything needed to launch a terminal surface. The terminal renderer is local
/// Ghostty, but the command always runs the Codevisor proxy, which connects to the
/// server that owns the session.
struct TerminalLaunchDescriptor: Equatable {
    /// The key the server's PTY manager stores this terminal under. One PTY
    /// per key; a session's first pane uses the bare session UUID (legacy)
    /// and later panes use "<sessionUuid>:<paneUuid>".
    let terminalKey: String
    /// Agent-owned background terminal: the proxy attaches to a registered
    /// terminal (retrying until it exists) instead of spawning a shell, and
    /// never closes it on teardown.
    let attachOnly: Bool
    let machine: CodevisorMachine
    let workingDirectory: URL
    let command: String

    static func make(
        session: ChatSession,
        project: Project,
        machine: CodevisorMachine,
        terminalKey: String,
        attachOnly: Bool = false,
        cwdOverride: String? = nil
    ) -> TerminalLaunchDescriptor {
        // Precedence: an explicit per-pane directory (a chat's worktree
        // picked on the New tab page), else the session's cwd (worktree
        // sessions open in the worktree), else the project folder. The
        // proxy passes the folder along via --cwd.
        let sessionFolder = cwdOverride.map(URL.init(fileURLWithPath:))
            ?? session.cwd.map(URL.init(fileURLWithPath:))
            ?? project.folderURL
        return TerminalLaunchDescriptor(
            terminalKey: terminalKey,
            attachOnly: attachOnly,
            machine: machine,
            workingDirectory: localWorkingDirectory(for: sessionFolder),
            command: TerminalProxyCommand.command(
                server: machine.baseURL,
                terminalKey: terminalKey,
                cwd: sessionFolder.path,
                token: machine.token,
                attachOnly: attachOnly
            )
        )
    }

    /// Ghostty spawns the proxy locally, so its working directory must exist on
    /// this Mac. Remote projects point at paths on the other machine (the pty
    /// still starts in the project folder remotely, via the proxy's --cwd).
    private static func localWorkingDirectory(for folderURL: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return folderURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

enum TerminalProxyCommand {
    nonisolated static func command(
        server: URL,
        terminalKey: String,
        cwd: String,
        token: String? = nil,
        attachOnly: Bool = false
    ) -> String {
        // The proxy's --session-id is an opaque key end-to-end (proxy, wire
        // schema, and the server's PTY map all treat it as a plain string).
        let args = [
            "--server", server.absoluteString,
            "--session-id", terminalKey,
            "--cwd", cwd
        ] + (token.map { ["--token", $0] } ?? [])
            + (attachOnly ? ["--attach-only", "true"] : [])
        let executable = proxyExecutable()
        return ([executable.command] + executable.prefixArgs + args)
            .map(shellQuote)
            .joined(separator: " ")
    }

    nonisolated private static func proxyExecutable() -> (command: String, prefixArgs: [String]) {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CODEVISOR_TERMINAL_PROXY"]
            ?? environment["HERDMAN_TERMINAL_PROXY"], !override.isEmpty {
            return (override, [])
        }
        if let entrypoint = proxyEntrypoint() {
            let node = LocalCodevisorServer.defaultNodeExecutable()
            let prefix = node.lastPathComponent == "env" ? ["node", entrypoint.path] : [entrypoint.path]
            return (node.path, prefix)
        }
        // Ghostty launches the command through `bash --noprofile --norc`, which
        // only sees the minimal system PATH — Homebrew's bin directories are
        // not on it, so resolve the brew-installed proxy by absolute path.
        let installedCandidates = [
            "/opt/homebrew/bin/codevisor-terminal-proxy",
            "/usr/local/bin/codevisor-terminal-proxy"
        ]
        if let installed = installedCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return (installed, [])
        }
        return ("/usr/bin/env", ["codevisor-terminal-proxy"])
    }

    nonisolated private static func proxyEntrypoint() -> URL? {
        if let runtimeDirectory = LocalCodevisorServer.bundledServerRuntimeDirectory() {
            let entrypoint = runtimeDirectory.appendingPathComponent("terminal-proxy.js")
            if FileManager.default.fileExists(atPath: entrypoint.path) {
                return entrypoint
            }
        }

        let bundledCandidates = [
            Bundle.main.url(forResource: "terminal-proxy", withExtension: "js", subdirectory: "server"),
            Bundle.main.url(forResource: "terminal-proxy", withExtension: "js", subdirectory: "Server"),
            Bundle.main.url(forResource: "codevisor-terminal-proxy", withExtension: "js")
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
/// to a working directory. Codevisor requires the libghostty-backed implementation;
/// builds should fail if `GhosttyKit` is unavailable.
@MainActor
protocol TerminalSurface: AnyObject {
    /// The view to embed in the terminal panel. The surface owns it for its
    /// whole lifetime so terminal state survives panel close + navigation.
    var nsView: NSView { get }
    /// Routes keyboard focus into (or out of) the terminal.
    func setFocused(_ focused: Bool)
    /// Tears down the shell/PTY and releases resources.
    func terminate()
    /// Invoked when the user asks to kill this terminal and start a fresh one
    /// (e.g. from the surface's context menu). The owner (TerminalPane)
    /// performs the actual kill + recreate.
    var onRestartRequest: (() -> Void)? { get set }
    /// Invoked for pane-group keyboard shortcuts (⌘⌥←/→, ⌘T) captured while
    /// this surface has keyboard focus.
    var onPaneCommand: ((PaneGroupCommand) -> Void)? { get set }
    /// Invoked when this surface gains/loses keyboard focus (first
    /// responder). Drives the pane bars' ⌘N shortcut hints.
    var onFocusChanged: ((Bool) -> Void)? { get set }
}

/// Creates terminal surfaces.
@MainActor
protocol TerminalSurfaceFactory {
    func makeSurface(descriptor: TerminalLaunchDescriptor) -> any TerminalSurface
}

/// Selects the terminal backend. The only supported backend is libghostty; a
/// missing `GhosttyKit` framework is a build error, not a degraded runtime mode.
@MainActor
enum TerminalRuntime {
    static let factory: any TerminalSurfaceFactory = GhosttyTerminalFactory.shared

    /// Eagerly initializes the terminal backend at app launch, in a clean
    /// context (not inside a SwiftUI update / event handler). This completes the
    /// libghostty runtime's `dispatch_once`-backed setup up front so opening the
    /// terminal later never re-enters an in-progress `once` (which traps with
    /// `_dispatch_once_wait` / EXC_BREAKPOINT).
    static func prewarm() {
        _ = CodevisorGhosttyApp.shared
    }
}
