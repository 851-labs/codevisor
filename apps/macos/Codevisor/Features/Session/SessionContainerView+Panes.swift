import SwiftUI
import CodevisorCore
import CodevisorUI

extension SessionContainerView {
  func configuredCenterModel(leafId: UUID) -> PaneGroupModel {
    let model = store.centerGroup(
      leafId: leafId,
      workspace: selectedWorkspace,
      session: session,
      project: project
    )
    let wiring = PaneGroupWiring(sourceId: focusSourceId, mountId: mountIdentity, project: project)
    guard model.wiring != wiring else { return model }
    model.wiring = wiring
    wire(model, leafId: leafId)
    return model
  }

  private func wire(_ model: PaneGroupModel, leafId: UUID) {
    model.onActivated = { [weak model] in
      let workspace = selectedWorkspace
      guard isVisible,
        store.navigationWorkspaceId == workspace.id,
        workspace.centerTree.group(id: leafId) != nil
      else { return }
      activateLeaf(leafId)
      if let model {
        sessionFocus.centerGroup = model
      }
    }
    model.isFocusCurrent = {
      isVisible && store.navigationWorkspaceId == selectedWorkspace.id && activeLeafId == leafId
    }
    model.workspaceCommandHandler = { command in
      handleWorkspaceCommand(command)
    }
    model.requestComposerFocus = { [weak model] in
      guard let selected = model?.state.selectedPane, selected.kind == .chat else { return }
      if let chatId = selected.chatSessionId {
        sessionFocus.requestComposerFocus(forChat: chatId)
      } else {
        sessionFocus.focusComposer()
      }
    }
    model.requestBackgroundFocus = { sessionFocus.focusPaneBackground() }
    model.onPaneEdited = { _ in
      guard let tab = selectedWorkspace.centerTabs.first(where: { $0.isPreview && $0.root.group(id: leafId) != nil })
      else { return }
      keepCenterTab(tab.id)
    }
    model.onPaneWillClose = { descriptor in
      rememberClosedPane(descriptor, leafId: leafId)
    }
    model.onPaneClosed = { descriptor in
      if descriptor.kind == .chat {
        if let closedSessionId = descriptor.chatSessionId {
          if let closed = environment.projectList.session(closedSessionId, serverId: selectedWorkspace.serverId) {
            environment.closeSession(closed)
          }
        } else {
          store.removePaneDraft(paneId: descriptor.id)
        }
      }
      if closingCenterTabId == nil {
        dissolveIfEmpty(leafId: leafId)
      }
    }
    model.canDissolve = { true }
    model.chatContent = { [weak model] descriptor in
      let workspace = selectedWorkspace
      if descriptor.kind == .subagent {
        return AnyView(
          SubagentPaneContentView(
            descriptor: descriptor,
            focus: sessionFocus,
            hostWorkspace: workspace,
            store: store,
            environment: environment
          ))
      }
      if descriptor.kind == .transcript {
        return AnyView(
          BotTranscriptPaneContentView(
            descriptor: descriptor,
            focus: sessionFocus,
            hostWorkspace: workspace,
            store: store,
            environment: environment
          ))
      }
      if descriptor.kind == .newTab {
        return AnyView(
          NewTabPageView(
            paneId: descriptor.id,
            group: model,
            onNewChat: { [weak model] in
              createChat(convertingPlaceholder: descriptor.id, in: model)
            },
            client: environment.machines.client(for: workspace.serverId),
            iconCacheNamespace: workspace.serverId,
            machineId: workspace.serverId
          ))
      }
      return AnyView(
        ChatPaneContentView(
          descriptor: descriptor,
          group: model,
          focus: sessionFocus,
          session: session,
          hostWorkspace: workspace,
          project: project,
          store: store,
          environment: environment,
          presentsBotConversation: descriptor.chatSessionId.flatMap(botChat)?.isConversational == true
        ))
    }
  }

  var focusedChatCandidate: UUID? {
    let workspace = selectedWorkspace
    guard isVisible, store.navigationWorkspaceId == workspace.id else { return nil }
    guard let leafId = workspace.selectedCenterTab?.resolvedActiveLeafId(preferred: activeLeafId) else {
      return nil
    }
    let model = store.centerGroup(
      leafId: leafId, workspace: workspace, session: session, project: project
    )
    guard let pane = model.state.selectedPane, pane.kind == .chat else { return nil }
    return pane.chatSessionId
  }

  func createChat(
    convertingPlaceholder paneId: UUID,
    in model: PaneGroupModel?
  ) {
    guard let model else { return }
    guard model.state.panes.contains(where: { $0.id == paneId }) else { return }
    let workspace = selectedWorkspace
    guard
      let created = NewChatPanePromoter.promote(
        paneId: paneId,
        in: model,
        project: project,
        workspace: workspace,
        environment: environment
      )
    else { return }
    sessionFocus.requestComposerFocus(forChat: created.id)
  }

  func dissolveIfEmpty(leafId: UUID) {
    var workspace = selectedWorkspace
    let model = store.centerGroup(
      leafId: leafId, workspace: workspace, session: session, project: project
    )
    guard model.state.panes.isEmpty else { return }
    guard
      let tabIndex = workspace.centerTabs.firstIndex(where: {
        $0.root.group(id: leafId) != nil
      })
    else { return }
    let previousActiveLeaf = activeLeafId ?? workspace.selectedCenterTab?.activeLeafId
    workspace.pruneClosedCenterTab(workspace.centerTabs[tabIndex].id)
    environment.workspaces.save(workspace)
    store.evictCenterLeaf(workspaceId: workspace.id, leafId: leafId)
    liveCenterTree = workspace.centerTree
    if previousActiveLeaf != workspace.selectedCenterTab?.activeLeafId {
      activateLeaf(workspace.selectedCenterTab?.activeLeafId)
    }
  }

  func publishPane(_ pane: PaneDescriptorState, workspaceId: UUID) {
    environment.workspaceSync.publishPane(
      pane,
      workspaceId: workspaceId,
      client: environment.machines.client(for: selectedWorkspace.serverId)
    )
  }

  func activateLeaf(_ leafId: UUID?) {
    guard let leafId else { return }
    let workspace = selectedWorkspace
    store.selectDestination(.leaf(leafId), in: workspace.id)
  }

  func paneTitle(_ descriptor: PaneDescriptorState) -> String {
    if descriptor.kind == .browser, let title = store.localBrowserTitle(paneId: descriptor.id) {
      return title
    }
    return descriptor.kind == .chat ? chatPaneTitle(descriptor) : descriptor.displayName
  }

  func chatPaneTitle(_ descriptor: PaneDescriptorState) -> String {
    guard let id = descriptor.chatSessionId else { return descriptor.name }
    return environment.projectList.session(id, serverId: selectedWorkspace.serverId)?.title ?? descriptor.name
  }
}

struct PaneGroupWiring: Equatable {
  let sourceId: UUID
  let mountId: UUID
  let project: Project
}
