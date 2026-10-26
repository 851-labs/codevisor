import CodevisorCore
import SwiftUI

struct BotTranscriptPaneContentView: View {
  let descriptor: PaneDescriptorState
  let focus: TerminalFocusController
  let hostWorkspace: Workspace
  let store: SessionStore
  let environment: AppEnvironment

  var body: some View {
    if let sessionId = descriptor.ownerChatSessionId,
      let session = environment.projectList.session(sessionId, serverId: hostWorkspace.serverId),
      let project = environment.projectList.projects.first(where: {
        $0.serverId == hostWorkspace.serverId && $0.id == session.projectId
      })
    {
      let controller = store.controller(for: session, project: project)
      ChatScreen(
        controller: controller,
        focus: focus,
        presentationSurface: store.transcriptSurface(
          for: session, paneID: descriptor.id, controller: controller),
        isReadOnly: true
      )
      .id(session.id)
      .accessibilityIdentifier("bot.fullTranscript")
      .task(id: SessionStore.SessionKey(session)) {
        store.noteAccess(SessionStore.SessionKey(session))
        await controller.connectIfNeeded()
      }
    } else {
      ContentUnavailableView(
        "Transcript Unavailable",
        systemImage: "text.page",
        description: Text("This bot's chat is no longer available.")
      )
    }
  }
}

extension SessionContainerView {
  func botChat(_ sessionId: UUID) -> Bot? {
    guard botsEnabled else { return nil }
    return environment.bots.bot(forSession: sessionId, serverId: selectedWorkspace.serverId)
  }

  func openBotTranscript(_ bot: Bot) {
    guard !isSinglePane else { return }
    var workspace = selectedWorkspace
    if let existing = workspace.allPanes.first(where: {
      $0.kind == .transcript && $0.ownerChatSessionId == bot.sessionId
    }) {
      store.selectDestination(.pane(existing.id), in: workspace.id)
      focusSelectedCenterPane()
      return
    }
    guard let botPane = workspace.pane(containingChat: bot.sessionId) else { return }
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .transcript, name: "Full Transcript", terminalKey: id.uuidString,
      ownerChatSessionId: bot.sessionId
    )
    guard let inserted = workspace.insertPane(pane, besidePane: botPane.id, destination: .foregroundTab)
    else { return }
    environment.workspaces.save(workspace)
    store.reconcileMountedPaneGroups(in: workspace)
    store.selectDestination(.tab(inserted.tabId), in: workspace.id)
    focusSelectedCenterPane()
  }
}
