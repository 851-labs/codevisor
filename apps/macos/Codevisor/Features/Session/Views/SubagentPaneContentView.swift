import CodevisorCore
import SwiftUI

/// A subagent pane: one of the parent chat's subagent threads, rendered by
/// the ordinary chat surface in read-only mode.
struct SubagentPaneContentView: View {
  let descriptor: PaneDescriptorState
  let focus: TerminalFocusController
  let hostWorkspace: Workspace
  let store: SessionStore
  let environment: AppEnvironment

  var body: some View {
    if let parentId = descriptor.ownerChatSessionId,
      let toolCallId = descriptor.subagentToolCallId,
      let parentSession = environment.projectList.session(parentId, serverId: hostWorkspace.serverId),
      let parentProject = environment.projectList.projects.first(where: {
        $0.serverId == hostWorkspace.serverId && $0.id == parentSession.projectId
      })
    {
      let parent = store.controller(for: parentSession, project: parentProject)
      let mirror = store.subagentMirror(
        workspaceId: hostWorkspace.id, paneId: descriptor.id, parent: parent, toolCallId: toolCallId)
      SubagentMirrorView(
        mirror: mirror,
        focus: focus,
        presentationSurface: store.transcriptSurface(
          for: parentSession, paneID: descriptor.id, controller: mirror.controller)
      )
      .id(ObjectIdentifier(mirror))
      // The parent chat owns the connection: keep it warm while its agent
      // is on screen, and connect it when this pane is restored first.
      .task(id: ObjectIdentifier(mirror)) {
        store.noteAccess(SessionStore.SessionKey(parentSession))
        mirror.start()
        await parent.connectIfNeeded()
      }
    } else {
      SubagentUnavailableView()
    }
  }
}

private struct SubagentMirrorView: View {
  let mirror: SubagentMirror
  let focus: TerminalFocusController
  let presentationSurface: TranscriptPresentationSurface

  var body: some View {
    content
      .onAppear { mirror.viewDidAppear() }
      .onDisappear { mirror.viewDidDisappear() }
  }

  @ViewBuilder
  private var content: some View {
    switch mirror.availability {
    case .available:
      ChatScreen(
        controller: mirror.controller,
        focus: focus,
        presentationSurface: presentationSurface,
        isReadOnly: true
      )
    case .loading:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .unavailable:
      SubagentUnavailableView()
    }
  }
}

private struct SubagentUnavailableView: View {
  var body: some View {
    ContentUnavailableView(
      "Agent Unavailable",
      systemImage: "wand.and.sparkles",
      description: Text("This agent is no longer in its chat's history.")
    )
  }
}

extension SessionStore {
  /// The mirror a subagent pane shows, owned by that pane until it leaves
  /// the workspace. A replaced parent controller (eviction, reconnect) gets a
  /// fresh mirror.
  func subagentMirror(
    workspaceId: UUID, paneId: UUID, parent: SessionController, toolCallId: String
  ) -> SubagentMirror {
    let key = SubagentPaneKey(workspaceId: workspaceId, paneId: paneId)
    if let mirror = subagentMirrors[key], mirror.parent === parent, mirror.toolCallId == toolCallId {
      return mirror
    }
    let mirror = SubagentMirror(parent: parent, toolCallId: toolCallId)
    subagentMirrors[key] = mirror
    return mirror
  }

  /// Drops the mirrors of subagent panes no longer in `workspace`.
  func pruneSubagentMirrors(in workspace: Workspace) {
    let open = Set(workspace.allPanes.lazy.filter { $0.kind == .subagent }.map(\.id))
    for key in subagentMirrors.keys where key.workspaceId == workspace.id && !open.contains(key.paneId) {
      subagentMirrors[key] = nil
    }
  }
}
