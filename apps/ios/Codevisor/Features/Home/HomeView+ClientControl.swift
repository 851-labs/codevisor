import CodevisorCore
import CodevisorUI
import Foundation
import SwiftUI

extension HomeView {
  func clientControlContext(serverId: String) -> NativeClientContext {
    let workspaceId: UUID?
    if case let .workspace(selectedServer, id, _, _, _)? = path.last, selectedServer == serverId {
      workspaceId = id
    } else {
      workspaceId = nil
    }
    var context = NativeClientContext.capture(
      repository: environment.workspaces, serverId: serverId,
      workspaceId: workspaceId, isActive: scenePhase == .active
    )
    context.capabilities = ClientCapabilities(settingsSections: SettingsSheet.clientSections, compact: true)
    context.page = ClientPageContext(
      page: path.isEmpty ? "home" : "workspace",
      settingsSection: presentedSettingsDestination == nil ? nil : clientSettingsSection,
      presentation: presentedSettingsDestination != nil ? "settings" : (presentedNewChatFlow == nil ? nil : "new_chat")
    )
    if let blocked = clientBlockingPresentation { context.page?.presentation = blocked }
    return context
  }

  func navigateClient(serverId: String, request: ClientNavigationRequest) async throws {
    try requireClientReady()
    guard presentedSettingsDestination == nil, newChatFlow == nil else {
      throw ClientControlError("Dismiss the presented sheet before navigating this client")
    }
    await environment.workspaceSync.refreshFromServer(
      serverId: serverId, client: environment.machines.client(for: serverId)
    )
    try Task.checkCancellation()
    guard let workspace = environment.workspaces.workspace(id: request.workspaceId),
      workspace.serverId == serverId
    else { throw ClientControlError("Workspace is not available on this machine") }
    let selected = try request.applying(to: workspace)
    let tab = selected.selectedCenterTab
    let pane = tab.flatMap { $0.root.group(id: $0.activeLeafId)?.selectedPane }
    let candidates = [pane?.chatSessionId].compactMap { $0 } + workspace.chatSessionIds
    guard
      let anchor = candidates.first(where: { id in
        projectList.sessions.contains { $0.serverId == serverId && $0.id == id }
      })
    else { throw ClientControlError("Workspace has no available chat route on this client") }
    environment.workspaces.save(selected)
    environment.workspaceSync.noteLocalMutation()
    path = [
      .workspace(
        serverId: serverId, workspaceId: workspace.id, anchorSessionId: anchor,
        preferredChatSessionId: nil, preferredPaneId: pane?.id
      )
    ]
  }

  func controlClient(serverId: String, action: ClientUIAction) async throws {
    try requireClientReady()
    switch action {
    case .window: throw ClientControlError("Window control is managed by iOS")
    case .page(let request): try await openClientPage(serverId: serverId, request: request)
    case .layout(let request):
      guard let workspace = environment.workspaces.workspace(id: request.workspaceId), workspace.serverId == serverId
      else {
        throw ClientControlError("Workspace is unavailable on this machine")
      }
      let updated = try request.applying(to: workspace, compact: true)
      environment.workspaces.save(updated)
      environment.workspaceSync.noteLocalMutation()
      workspaceRevision += 1
      let oldIds = Set(workspace.centerTabs.flatMap { $0.root.allGroups.flatMap { $0.state.panes.map(\.id) } })
      for pane in updated.centerTabs.flatMap({ $0.root.allGroups.flatMap(\.state.panes) })
      where !oldIds.contains(pane.id) {
        environment.workspaceSync.publishPane(
          pane, workspaceId: workspace.id, client: environment.machines.client(for: serverId))
      }
    }
  }

  func requireClientReady() throws {
    if let blocked = clientBlockingPresentation {
      throw ClientControlError("Dismiss \(blocked) before controlling this client")
    }
  }

  func openClientPage(serverId: String, request: ClientPageRequest) async throws {
    if request.page == "dismiss" {
      if let flow = newChatFlow {
        guard flow.phase == .composing else { throw ClientControlError("New Chat is being submitted") }
        try await clientPresentationCompletion.dismiss("new_chat") { presentedNewChatFlow = nil }
      }
      try await dismissClientSettings()
      return
    }
    guard newChatFlow == nil else {
      throw ClientControlError("Dismiss the New Chat sheet first; its draft will be retained")
    }
    switch request.page {
    case "home":
      try await dismissClientSettings()
      path = []
    case "new_chat":
      guard presentedSettingsDestination == nil else {
        throw ClientControlError("Dismiss Settings before opening New Chat")
      }
      if let id = request.projectId {
        guard let project = projectList.projects.first(where: { $0.serverId == serverId && $0.id == id }) else {
          throw ClientControlError("Project is unavailable on this machine")
        }
        let controller = ChatControllerCache.shared.draftController(preferredProject: project, environment: environment)
        await controller.retarget(to: project, serverClient: environment.machines.client(for: serverId))
        try Task.checkCancellation()
      }
      presentNewChat(serverId: serverId)
    case "settings":
      let section = request.section ?? "root"
      guard SettingsSheet.clientSections.contains(section) else {
        throw ClientControlError("Settings section is unsupported on this client")
      }
      clientSettingsSection = section
      switch section {
      case "root": presentedSettingsDestination = .root
      case "machines": presentedSettingsDestination = .machines(focusedMachineID: serverId)
      default: presentedSettingsDestination = .section(section)
      }
    default: throw ClientControlError("Page is unsupported on this client")
    }
  }

  func dismissClientSettings() async throws {
    if presentedSettingsDestination != nil {
      try await clientPresentationCompletion.dismiss("settings") { presentedSettingsDestination = nil }
    }
  }
}
