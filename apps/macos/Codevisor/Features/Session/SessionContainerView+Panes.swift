import SwiftUI
import CodevisorCore
import CodevisorUI

// MARK: - Panes

extension SessionContainerView {
  /// A center leaf's model with the container's lifecycle hooks attached
  /// (idempotent — models are cached).
  func configuredCenterModel(leafId: UUID) -> PaneGroupModel {
    let model = store.centerGroup(
      leafId: leafId,
      workspace: store.workspace(for: session, project: project),
      session: session,
      project: project
    )
    // Acting in a group makes it the ACTIVE one: keyboard tab commands
    // follow the user (routed via the focus controller's centerGroup).
    model.onActivated = { [weak model] in
      activateLeaf(leafId)
      if let model {
        sessionFocus.centerGroup = model
        if let chatId = model.state.selectedPane?.chatSessionId {
          rememberWorkspaceDefaults(from: chatId)
        }
      }
    }
    model.workspaceCommandHandler = { command in
      handleWorkspaceCommand(command)
    }
    // Selecting a chat tab focuses ITS composer — keyed and deferred,
    // since switching tabs remounts the chat and the composer registers
    // a tick later. ONLY chat panes: any other selected kind (New Tab
    // placeholder) must not steal focus into some arbitrary composer.
    // ⌘J relays to the session screen's toggle.
    model.requestComposerFocus = { [weak model] in
      guard let selected = model?.state.selectedPane, selected.kind == .chat else { return }
      if let chatId = selected.chatSessionId {
        sessionFocus.requestComposerFocus(forChat: chatId)
      } else {
        sessionFocus.focusComposer()
      }
    }
    model.requestBackgroundFocus = { sessionFocus.focusPaneBackground() }
    model.requestToggle = { sessionFocus.requestPanelToggle?() }
    model.onPaneClosed = { descriptor in
      rememberClosedPane(descriptor, leafId: leafId)
      if descriptor.kind == .chat {
        if let closedSessionId = descriptor.chatSessionId {
          // Closing an established chat's tab ARCHIVES its
          // session (recoverable from the archived list); the
          // session itself always survives.
          if let closed = environment.projectList.sessions.first(where: {
            $0.serverId == session.serverId && $0.id == closedSessionId
          }) {
            environment.archiveSession(closed)
          }
          // The ROUTED chat left: hand the route to the
          // workspace's first surviving chat, so the sidebar
          // never points at an archived session (focus may land
          // on a terminal, which reports nothing).
          if closedSessionId == session.id,
            closingCenterTabId == nil,
            let survivor = firstSurvivingChatId()
          {
            onFocusedChatChanged?(survivor)
          }
        } else {
          // A draft closed unsent: discard its composer state.
          store.removePaneDraft(paneId: descriptor.id)
        }
      }
      if closingCenterTabId == nil {
        dissolveIfEmpty(leafId: leafId)
      }
    }
    // A lone New Tab placeholder's close dissolves its group — possible
    // whenever the workspace has other groups.
    model.canDissolve = { true }
    // Any center group can host chats (established or draft) and the
    // New Tab placeholder. Weak model: the closure is held BY the model.
    // Re-wired UNCONDITIONALLY (safe: @ObservationIgnored): the models
    // are cached across containers, and this closure captures THIS
    // container's focus controller — a stale capture makes every chat
    // pane register its composer with a dead controller, orphaning the
    // new container's focus intents.
    model.chatContent = { [weak model] descriptor in
      if descriptor.kind == .newTab {
        return AnyView(
          NewTabPageView(
            paneId: descriptor.id,
            group: model,
            onNewChat: { [weak model] in
              createChat(convertingPlaceholder: descriptor.id, in: model)
            },
            client: environment.machines.client(for: session.serverId),
            iconCacheNamespace: session.serverId
          ))
      }
      return AnyView(
        ChatPaneContentView(
          descriptor: descriptor,
          group: model,
          focus: sessionFocus,
          session: session,
          project: project,
          store: store,
          environment: environment
        ))
    }
    return model
  }

  /// The chat pane facing the user: the selected pane of the active split
  /// leaf, when it is a chat. Reads the live group model so pane selection
  /// changes re-evaluate the publisher above.
  var focusedChatCandidate: UUID? {
    let workspace = store.workspace(for: session, project: project)
    guard let leafId = activeLeafId ?? workspace.selectedCenterTab?.activeLeafId else {
      return nil
    }
    let model = store.centerGroup(
      leafId: leafId, workspace: workspace, session: session, project: project
    )
    guard let pane = model.state.selectedPane, pane.kind == .chat else { return nil }
    return pane.chatSessionId
  }

  /// "New Chat" from a New tab page: creates the SESSION eagerly — a real
  /// chat from birth (sidebar row, archive-on-close, focus-follow), not a
  /// deferred draft — in the workspace's one working directory with the
  /// default harness, then converts the placeholder in place.
  func createChat(
    convertingPlaceholder paneId: UUID,
    in model: PaneGroupModel?
  ) {
    guard let model else { return }
    guard model.state.panes.contains(where: { $0.id == paneId }) else { return }
    let workspace = store.workspace(for: session, project: project)
    guard
      let created = NewChatPanePromoter.promote(
        paneId: paneId,
        in: model,
        project: project,
        workspace: workspace,
        environment: environment
      )
    else { return }
    // The pane's composer takes focus once it mounts; the responder
    // observer then walks the sidebar selection over to the new chat.
    sessionFocus.requestComposerFocus(forChat: created.id)
  }

  /// Removes an emptied split leaf. A layout may need an empty shell, but
  /// that shell is not a shared pane and is never uploaded as New Tab.
  func dissolveIfEmpty(leafId: UUID) {
    var workspace = store.workspace(for: session, project: project)
    let model = store.centerGroup(
      leafId: leafId, workspace: workspace, session: session, project: project
    )
    guard model.state.panes.isEmpty else { return }
    guard
      let tabIndex = workspace.centerTabs.firstIndex(where: {
        $0.root.group(id: leafId) != nil
      })
    else { return }
    let oldLeafIds = workspace.centerTabs[tabIndex].root.allGroups.map(\.id)
    if let pruned = workspace.centerTabs[tabIndex].root.removingGroup(id: leafId) {
      workspace.centerTabs[tabIndex].root = pruned
      let oldIndex = oldLeafIds.firstIndex(of: leafId) ?? 0
      let survivors = pruned.allGroups.map(\.id)
      workspace.centerTabs[tabIndex].activeLeafId =
        survivors[
          min(oldIndex, survivors.count - 1)
        ]
      environment.workspaces.save(workspace)
      liveCenterTree = pruned
      store.evictCenterLeaf(workspaceId: workspace.id, leafId: leafId)
      workspaceRevision += 1
      activateLeaf(workspace.centerTabs[tabIndex].activeLeafId)
    } else {
      let closingTabId = workspace.centerTabs[tabIndex].id
      workspace.centerTabs.remove(at: tabIndex)
      if workspace.centerTabs.isEmpty {
        let replacement = WorkspaceTab(root: .leaf(PaneGroupState()))
        workspace.centerTabs = [replacement]
        workspace.selectedCenterTabId = replacement.id
      } else if workspace.selectedCenterTabId == closingTabId {
        workspace.selectedCenterTabId =
          workspace.centerTabs[
            min(tabIndex, workspace.centerTabs.count - 1)
          ].id
      }
      environment.workspaces.save(workspace)
      store.evictCenterLeaf(workspaceId: workspace.id, leafId: leafId)
      workspaceRevision += 1
      liveCenterTree = workspace.centerTree
      activateLeaf(workspace.selectedCenterTab?.activeLeafId)
    }
  }

  func publishPane(_ pane: PaneDescriptorState, workspaceId: UUID) {
    environment.workspaceSync.publishPane(
      pane,
      workspaceId: workspaceId,
      client: environment.machines.client(for: session.serverId)
    )
  }

  /// Makes a leaf the active group (keyboard routing + hints).
  func activateLeaf(_ leafId: UUID?) {
    activeLeafId = leafId
    if let leafId {
      var workspace = store.workspace(for: session, project: project)
      if let tabIndex = workspace.centerTabs.firstIndex(where: {
        $0.root.group(id: leafId) != nil
      }) {
        var changed = false
        if workspace.selectedCenterTabId != workspace.centerTabs[tabIndex].id {
          workspace.selectedCenterTabId = workspace.centerTabs[tabIndex].id
          liveCenterTree = workspace.centerTabs[tabIndex].root
          changed = true
        }
        if workspace.centerTabs[tabIndex].activeLeafId != leafId {
          workspace.centerTabs[tabIndex].activeLeafId = leafId
          changed = true
        }
        if changed {
          environment.workspaces.save(workspace)
          workspaceRevision += 1
        }
      }
      sessionFocus.centerGroup = configuredCenterModel(leafId: leafId)
    }
  }

  /// Promotes the focused chat's live configuration into the workspace
  /// inheritance profile. An eagerly-created unsent chat has its separate
  /// pane-draft controller and already writes to this scope directly, so do
  /// not mint a duplicate session controller for it.
  func rememberWorkspaceDefaults(fromLeaf leafId: UUID, in workspace: Workspace) {
    guard let selected = workspace.selectedPane(inLeaf: leafId),
      selected.kind == .chat
    else { return }
    if let chatId = selected.chatSessionId {
      rememberWorkspaceDefaults(from: chatId)
    } else {
      store.paneDraftController(forPane: selected.id)?
        .rememberCurrentComposerConfiguration()
    }
  }

  func rememberWorkspaceDefaults(from chatId: UUID) {
    guard
      let chat = environment.projectList.sessions.first(where: {
        $0.serverId == session.serverId && $0.id == chatId
      })
    else { return }
    if let live = store.activeController(for: chat) {
      if let chatProject = environment.projectList.projects.first(where: {
        $0.serverId == chat.serverId && $0.id == chat.projectId
      }) {
        store.reconcile(live, for: chat, project: chatProject)
      }
      live.rememberCurrentComposerConfiguration()
      return
    }
    guard chat.agentSessionId?.isEmpty == false,
      let chatProject = environment.projectList.projects.first(where: {
        $0.serverId == chat.serverId && $0.id == chat.projectId
      })
    else { return }
    let controller = store.controller(for: chat, project: chatProject)
    store.reconcile(controller, for: chat, project: chatProject)
    controller.rememberCurrentComposerConfiguration()
  }

  /// A chat pane's display title: its referenced session's LIVE title
  /// (auto-titles and renames flow through); drafts show their own name.
  func paneTitle(_ descriptor: PaneDescriptorState) -> String {
    descriptor.kind == .chat ? chatPaneTitle(descriptor) : descriptor.name
  }

  func chatPaneTitle(_ descriptor: PaneDescriptorState) -> String {
    guard let id = descriptor.chatSessionId else { return descriptor.name }
    return environment.projectList.sessions.first {
      $0.serverId == session.serverId && $0.id == id
    }?.title ?? descriptor.name
  }

  func firstSurvivingChatId() -> UUID? {
    let descriptors = store.workspace(for: session, project: project)
      .centerTabs.flatMap { tab in tab.root.allGroups }
      .flatMap { group in group.state.panes }
    return descriptors.first { descriptor in
      guard descriptor.kind == .chat,
        let candidateId = descriptor.chatSessionId
      else { return false }
      return environment.projectList.sessions.contains { candidate in
        candidate.serverId == session.serverId
          && candidate.id == candidateId
          && !candidate.isArchived
      }
    }?.chatSessionId
  }

  /// Every chat in the workspace with a live cached controller, routed
  /// session included. Controllers are never MINTED here (pure reads) —
  /// a chat whose controller isn't cached contributes nothing, and its
  /// persisted tabs survive untouched until it reconnects.
  var workspaceChatControllers: [(chatId: UUID, controller: SessionController)] {
    let workspace = store.workspace(for: session, project: project)
    return workspace.chatSessionIds.compactMap { chatId in
      guard
        let chat = environment.projectList.sessions.first(where: {
          $0.serverId == session.serverId && $0.id == chatId
        }), let controller = store.activeController(for: chat)
      else { return nil }
      return (chatId, controller)
    }
  }

  /// Equatable digest of every chat's background-task state; onChange over
  /// this re-syncs when any task starts/ends or a snapshot arrives.
  var backgroundTaskFingerprint: [String] {
    workspaceChatControllers.flatMap { chatId, controller -> [String] in
      let tasks = controller.backgroundTasks.compactMap { task in
        task.terminalKey.map { "\(chatId.uuidString)|\($0)|\(task.description)" }
      }
      return tasks + ["\(chatId.uuidString)|snapshot:\(controller.hasBackgroundTaskSnapshot)"]
    }
  }

  func syncWorkspaceBackgroundTerminals() {
    let panel = store.paneGroup(for: session, project: project)
    for (chatId, controller) in workspaceChatControllers {
      panel.syncAgentTerminals(
        controller.backgroundTasks.compactMap { task in
          task.terminalKey.map { (terminalKey: $0, name: task.description) }
        },
        owner: chatId,
        pruneEnded: controller.hasBackgroundTaskSnapshot
      )
    }
  }
}
