import AppKit
import CodevisorCore
import SwiftUI

@MainActor
final class BotTranscriptWindows {
  static let shared = BotTranscriptWindows()

  private static let initialSize = NSSize(width: 760, height: 820)

  private struct Presentation {
    let window: NSWindow
    let paneID: UUID
    let store: SessionStore
  }

  private var presentations: [UUID: Presentation] = [:]
  private var closeObservers: [UUID: NSObjectProtocol] = [:]

  func present(_ bot: Bot, workspace: Workspace, store: SessionStore, environment: AppEnvironment) {
    let presentation =
      presentations[bot.id] ?? makePresentation(bot, workspace: workspace, store: store, environment: environment)
    presentations[bot.id] = presentation
    presentation.window.makeKeyAndOrderFront(nil)
  }

  private func makePresentation(
    _ bot: Bot, workspace: Workspace, store: SessionStore, environment: AppEnvironment
  ) -> Presentation {
    let paneID = UUID()
    let host = NSHostingController(rootView: content(bot, paneID, workspace, store, environment))
    let window = NSWindow(contentViewController: host)
    window.title = "\(bot.name) – Full Transcript"
    window.setContentSize(Self.initialSize)
    window.isReleasedWhenClosed = false
    window.center()
    closeObservers[bot.id] = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.closed(bot) }
    }
    return Presentation(window: window, paneID: paneID, store: store)
  }

  private func closed(_ bot: Bot) {
    guard let presentation = presentations.removeValue(forKey: bot.id) else { return }
    presentation.window.contentViewController = nil
    presentation.store.releaseTranscriptViewer(paneID: presentation.paneID, sessionID: bot.sessionId)
    closeObservers.removeValue(forKey: bot.id).map(NotificationCenter.default.removeObserver)
  }

  @ViewBuilder
  private func content(
    _ bot: Bot, _ paneID: UUID, _ workspace: Workspace, _ store: SessionStore, _ environment: AppEnvironment
  ) -> some View {
    let descriptor = PaneDescriptorState(
      id: paneID, kind: .transcript, name: "Full Transcript", terminalKey: paneID.uuidString,
      ownerChatSessionId: bot.sessionId)
    Group {
      if let project = environment.projectList.projects.first(where: {
        $0.serverId == workspace.serverId && $0.id == bot.projectId
      }) {
        ChatPaneContentView(
          descriptor: descriptor, group: nil, focus: TerminalFocusController(), session: nil,
          hostWorkspace: workspace, project: project, store: store, environment: environment,
          role: .fullTranscript
        )
      } else {
        ContentUnavailableView(
          "Transcript Unavailable",
          systemImage: "text.page",
          description: Text("This bot's chat is no longer available.")
        )
      }
    }
    .environment(environment)
    .themedRoot()
  }
}
