import AppKit
import CodevisorCore
import SwiftUI

final class BotTranscriptWindows {
  static let shared = BotTranscriptWindows()

  private static let initialSize = NSSize(width: 760, height: 820)

  private var windows: [UUID: NSWindow] = [:]

  func present(_ bot: Bot, workspace: Workspace, store: SessionStore, environment: AppEnvironment) {
    let window = windows[bot.id] ?? makeWindow(bot, workspace: workspace, store: store, environment: environment)
    windows[bot.id] = window
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow(
    _ bot: Bot, workspace: Workspace, store: SessionStore, environment: AppEnvironment
  ) -> NSWindow {
    let host = NSHostingController(rootView: content(bot, workspace, store, environment))
    let window = NSWindow(contentViewController: host)
    window.title = "\(bot.name) – Full Transcript"
    window.setContentSize(Self.initialSize)
    window.isReleasedWhenClosed = false
    window.center()
    return window
  }

  private func content(
    _ bot: Bot, _ workspace: Workspace, _ store: SessionStore, _ environment: AppEnvironment
  ) -> some View {
    let id = UUID()
    let descriptor = PaneDescriptorState(
      id: id, kind: .transcript, name: "Full Transcript", terminalKey: id.uuidString,
      ownerChatSessionId: bot.sessionId)
    return BotTranscriptPaneContentView(
      descriptor: descriptor, focus: TerminalFocusController(), hostWorkspace: workspace, store: store,
      environment: environment
    )
    .environment(environment)
    .themedRoot()
  }
}
