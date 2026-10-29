import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

struct WorkspacePreferredRoute: Equatable {
  var chatSessionId: UUID?
  var paneId: UUID?
}

struct WorkspacePaneSelection: Equatable {
  var workspaceId: UUID
  var paneId: UUID
}

extension WorkspaceScreen {
  var preferredRoute: WorkspacePreferredRoute {
    WorkspacePreferredRoute(chatSessionId: preferredChatSessionId, paneId: preferredPaneId)
  }

  var reportedPaneSelection: WorkspacePaneSelection? {
    guard paneState != nil, let workspaceId, let paneId = panes.selectedPaneId else { return nil }
    return WorkspacePaneSelection(workspaceId: workspaceId, paneId: paneId)
  }

  func applyPreferredRoute() {
    guard paneState != nil else { return }
    var state = panes
    var openedPane: PaneDescriptorState?
    if let preferredChatSessionId {
      if let pane = state.panes.first(where: {
        $0.kind == .chat && $0.chatSessionId == preferredChatSessionId
      }) {
        state.selectPane(id: pane.id)
      } else {
        openedPane = state.addChatPane(sessionId: preferredChatSessionId)
      }
    }
    if let preferredPaneId {
      state.selectPane(id: preferredPaneId)
    }
    guard state != panes else { return }
    paneBinding.wrappedValue = state
    if let openedPane { publishPane(openedPane) }
    IOSNavigationDiagnostics.record(
      "workspace.applyPreferredRoute",
      "chat=\(preferredChatSessionId.map(Self.diagnosticID) ?? "nil") "
        + "pane=\(preferredPaneId.map(Self.diagnosticID) ?? "nil") "
        + "selected=\(state.selectedPaneId.map(Self.diagnosticID) ?? "nil")"
    )
  }

  func select(_ pane: PaneDescriptorState) {
    var state = panes
    state.selectPane(id: pane.id)
    paneBinding.wrappedValue = state
  }

  func close(_ pane: PaneDescriptorState) {
    guard resolvedWorkspace?.isMainChatPane(pane) != true else { return }
    let owningWorkspaceId = resolvedWorkspace?.id
    var state = panes
    let replacement: PaneDescriptorState?
    if state.panes.count == 1 {
      replacement = state.replacePaneWithNewTab(id: pane.id)
      guard replacement != nil else { return }
    } else {
      replacement = nil
      guard state.closePane(id: pane.id) != nil else { return }
    }
    withAnimation(Motion.listReflow(reduceMotion: accessibilityReduceMotion)) {
      paneBinding.wrappedValue = state
    }
    if pane.kind == .plugin {
      PluginPaneCache.shared.remove(paneId: pane.id)
      PluginAppPaneModels.shared.remove(paneId: pane.id)
    }
    if pane.kind == .browser {
      BrowserPaneCache.shared.remove(paneId: pane.id)
    }
    if pane.kind == .document { FilePaneCache.shared.remove(paneId: pane.id) }
    if pane.kind == .review { ReviewPaneCache.shared.remove(paneId: pane.id) }
    if pane.kind == .simulator { SimulatorPaneCache.shared.remove(paneId: pane.id) }
    if pane.kind == .screenSharing { ScreenSharingPaneCache.shared.remove(paneId: pane.id) }
    if pane.kind == .terminal { TerminalSessionCache.shared.remove(terminalKey: pane.terminalKey) }
    if pane.kind == .chat {
      TranscriptPresentationSurfaceCache.shared.remove(paneID: pane.id)
      if let original = paneViewIdentities[pane.id], original != pane.id {
        TranscriptPresentationSurfaceCache.shared.remove(paneID: original)
      }
    }
    if pane.kind == .chat, let sessionId = pane.chatSessionId, let closed = session(for: sessionId) {
      environment.closeSession(closed)
    }
    if let workspaceId = owningWorkspaceId {
      environment.workspaceSync.deletePane(
        id: pane.id,
        workspaceId: workspaceId,
        optimisticReplacement: replacement,
        client: environment.machines.client(for: resolvedServerId)
      )
    }
  }

  func addTab() {
    var state = panes
    let newPane = state.addNewTabPane()
    state.selectPane(id: newPane.id)
    paneBinding.wrappedValue = state
    publishPane(newPane)
  }
}
