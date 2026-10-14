import AppKit
import Foundation
import CodevisorCore
import CodevisorCoreMac

struct TerminalLaunchDescriptor {
  let terminalKey: String
  let machine: CodevisorMachine
  let serverConfig: CodevisorServerConfig
  let workingDirectory: String

  static func make(
    session: ChatSession?,
    project: Project,
    machine: CodevisorMachine,
    serverConfig: CodevisorServerConfig? = nil,
    terminalKey: String,
    workspaceRootDirectory: String? = nil
  ) -> TerminalLaunchDescriptor {
    let folder = PaneWorkingDirectory.resolve(
      anchor: session.map { .session(cwd: $0.cwd) } ?? .workspace,
      workspaceRootDirectory: workspaceRootDirectory,
      projectFolderPath: project.folderURL.path)
    return TerminalLaunchDescriptor(
      terminalKey: terminalKey,
      machine: machine,
      serverConfig: serverConfig ?? machine.serverConfig,
      workingDirectory: folder
    )
  }
}

@MainActor
protocol TerminalSurface: AnyObject {
  var nsView: NSView { get }
  func setFocused(_ focused: Bool)
  func setVisible(_ visible: Bool)
  func terminate()
  var onRestartRequest: (() -> Void)? { get set }
  var onPaneCommand: ((PaneGroupCommand) -> Void)? { get set }
  var onFocusChanged: ((Bool) -> Void)? { get set }
}

@MainActor
protocol TerminalSurfaceFactory {
  func makeSurface(descriptor: TerminalLaunchDescriptor) -> any TerminalSurface
}

@MainActor
enum TerminalRuntime {
  static let factory: any TerminalSurfaceFactory = GhosttyTerminalFactory.shared

  static func prewarm() {
    _ = CodevisorGhosttyApp.shared
  }
}
