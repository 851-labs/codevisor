import AppKit
import Foundation
import CodevisorCore
import CodevisorCoreMac

/// Everything needed to open a terminal surface. The terminal renders in local
/// Ghostty; the shell runs on the server that owns the session, and the surface
/// talks to it directly (host-managed I/O — no local process).
struct TerminalLaunchDescriptor {
  /// The key the server's PTY manager stores this terminal under. One PTY
  /// per key; a session's first pane uses the bare session UUID (legacy)
  /// and later panes use "<sessionUuid>:<paneUuid>".
  let terminalKey: String
  /// Agent-owned background terminal: attach to a registered terminal
  /// instead of spawning a shell, and never close it on teardown.
  let attachOnly: Bool
  let machine: CodevisorMachine
  /// Relay-aware connection to the machine (cloud machines tunnel through
  /// the in-process relay transports).
  let serverConfig: CodevisorServerConfig
  /// The shell's starting directory on the server's machine.
  let workingDirectory: String

  static func make(
    session: ChatSession?,
    project: Project,
    machine: CodevisorMachine,
    serverConfig: CodevisorServerConfig? = nil,
    terminalKey: String,
    attachOnly: Bool = false,
    workspaceRootDirectory: String? = nil
  ) -> TerminalLaunchDescriptor {
    // The session's cwd IS the workspace's one working directory
    // (worktree sessions open in the worktree), else the project
    // folder. Without a session the workspace's own directory takes that place.
    let folder = PaneWorkingDirectory.resolve(
      anchor: session.map { .session(cwd: $0.cwd) } ?? .workspace,
      workspaceRootDirectory: workspaceRootDirectory,
      projectFolderPath: project.folderURL.path)
    return TerminalLaunchDescriptor(
      terminalKey: terminalKey,
      attachOnly: attachOnly,
      machine: machine,
      serverConfig: serverConfig ?? machine.serverConfig,
      workingDirectory: folder
    )
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
  /// The surface went on or off screen: only on-screen clients size the
  /// server's PTY.
  func setVisible(_ visible: Bool)
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
