import CodevisorCore
import Foundation
import SwiftUI
import AppKit

extension RootView {
  func clientControlContext(serverId: String) -> NativeClientContext {
    let workspaceId: UUID?
    if case let .session(selectedServer, sessionId) = selection, selectedServer == serverId {
      workspaceId = environment.workspaces.workspaceId(forSession: sessionId)
    } else {
      workspaceId = nil
    }
    var context = NativeClientContext.capture(
      repository: environment.workspaces, serverId: serverId,
      workspaceId: workspaceId, isActive: clientWindow.window?.isKeyWindow == true
    )
    context.capabilities = ClientCapabilities(settingsSections: SettingsTab.allCases.map(\.rawValue), compact: false)
    context.window = clientWindow.context(sidebarVisible: clientSidebarVisible)
    let settings = SettingsRouter.shared
    context.page = ClientPageContext(
      page: {
        if case .session = selection { return "workspace" }; return "new_chat"
      }(),
      settingsSection: settings.controlWindow?.isVisible == true ? settings.selectedTab.rawValue : nil,
      presentation: settings.controlWindow?.isVisible == true ? "settings" : nil
    )
    if !environment.settings.hasCompletedOnboarding { context.page = .init(page: "onboarding") }
    return context
  }

  func navigateClient(serverId: String, request: ClientNavigationRequest) async throws {
    try requireClientReady()
    guard let store else { throw ClientControlError("Window is still loading") }
    await environment.workspaceSync.refreshFromServer(
      serverId: serverId, client: environment.machines.client(for: serverId)
    )
    try Task.checkCancellation()
    guard let workspace = environment.workspaces.workspace(id: request.workspaceId),
      workspace.serverId == serverId
    else { throw ClientControlError("Workspace is not available on this machine") }
    let selected = try request.applying(to: workspace)
    let tab = selected.selectedCenterTab
    let selectedChat = tab.flatMap { $0.root.group(id: $0.activeLeafId)?.selectedPane?.chatSessionId }
    let candidates = [selectedChat].compactMap { $0 } + workspace.chatSessionIds
    guard
      let anchor = candidates.first(where: { id in
        environment.projectList.sessions.contains { $0.serverId == serverId && $0.id == id }
      })
    else { throw ClientControlError("Workspace has no available chat route on this client") }
    guard
      store.selectDestination(
        request.destination?.workspaceDestination ?? .tab(selected.selectedCenterTabId),
        in: workspace.id
      )
    else { throw ClientControlError("Destination is no longer available") }
    selection = .session(serverId: serverId, id: anchor)
  }

  var clientSidebarVisible: Bool {
    panelLayout.docksSidebar ? !sidebarCollapsed : panelLayout.activeDrawer == .leading
  }

  func requireClientReady() throws {
    guard environment.settings.hasCompletedOnboarding else { throw ClientControlError("Complete onboarding first") }
    guard clientWindow.window?.attachedSheet == nil else {
      throw ClientControlError("Dismiss the window's sheet first")
    }
  }

  func controlClient(serverId: String, action: ClientUIAction) async throws {
    try requireClientReady()
    switch action {
    case .page(let request): try await openClientPage(serverId: serverId, request: request)
    case .layout(let request): try applyClientLayout(serverId: serverId, request: request)
    case .window(let request):
      if request.action == "sidebar" {
        guard let visible = request.visible else { throw ClientControlError("Missing sidebar visibility") }
        if panelLayout.docksSidebar {
          sidebarCollapsed = !visible
        } else if visible != clientSidebarVisible {
          panelLayout.toggleDrawer(.leading)
        }
      } else {
        try await clientWindow.perform(request)
      }
    }
  }

  func openClientPage(serverId: String, request: ClientPageRequest) async throws {
    let router = SettingsRouter.shared
    switch request.page {
    case "home", "new_chat":
      let target: NewChatTarget?
      if let id = request.projectId {
        guard environment.projectList.projects.contains(where: { $0.serverId == serverId && $0.id == id }) else {
          throw ClientControlError("Project is unavailable on this machine")
        }
        target = NewChatTarget(serverId: serverId, projectId: id)
      } else {
        target = nil
      }
      selection = .newChat(target)
      clientWindow.window?.makeKeyAndOrderFront(nil)
    case "settings":
      guard let tab = SettingsTab(rawValue: request.section ?? "general") else {
        throw ClientControlError("Settings section is unsupported on this client")
      }
      guard router.controlWindow?.attachedSheet == nil else {
        throw ClientControlError("Dismiss the Settings sheet first")
      }
      router.panePath = []
      router.selectedTab = tab
      if router.controlWindow?.isVisible == true {
        openClientSettings()
      } else {
        try await acknowledgeWindowChange(
          window: router.controlWindow, notification: NSWindow.didBecomeKeyNotification,
          matches: { $0 === router.controlWindow }
        ) {
          openClientSettings()
        }
      }
    case "dismiss":
      guard router.controlWindow?.attachedSheet == nil else {
        throw ClientControlError("Dismiss the Settings sheet first")
      }
      router.controlWindow?.close()
      clientWindow.window?.makeKeyAndOrderFront(nil)
    default: throw ClientControlError("Page is unsupported on this client")
    }
  }

  func applyClientLayout(serverId: String, request: ClientLayoutRequest) throws {
    guard let store, let workspace = environment.workspaces.workspace(id: request.workspaceId),
      workspace.serverId == serverId
    else { throw ClientControlError("Workspace is unavailable on this machine") }
    let updated = try request.applying(to: workspace, compact: false)
    environment.workspaces.save(updated)
    store.reconcileMountedPaneGroups(in: updated)
    store.workspaceLayoutRevision += 1
    if request.focus == true { store.navigationRevision &+= 1 }
    environment.workspaceSync.noteLocalMutation()
    let oldIds = Set(workspace.centerTabs.flatMap { $0.root.allGroups.flatMap { $0.state.panes.map(\.id) } })
    for pane in updated.centerTabs.flatMap({ $0.root.allGroups.flatMap(\.state.panes) }) where !oldIds.contains(pane.id)
    {
      environment.workspaceSync.publishPane(
        pane, workspaceId: workspace.id, client: environment.machines.client(for: serverId))
    }
  }
}
