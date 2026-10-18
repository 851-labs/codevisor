import Foundation
import Observation
import SwiftUI
import CodevisorCore

extension PaneGroupModel {
  func assignChatSession(paneId: UUID, sessionId: UUID, name: String) {
    state.assignChatSession(paneId: paneId, sessionId: sessionId, name: name)
    persist()
    if let pane = state.panes.first(where: { $0.id == paneId }) { onPaneChanged?(pane) }
  }

  func renamePane(id: UUID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let index = state.panes.firstIndex(where: { $0.id == id }),
      state.panes[index].name != trimmed
    else { return }
    state.panes[index].name = trimmed
    persist()
    onPaneChanged?(state.panes[index])
  }

  func resetChatPaneToPlaceholder(id: UUID) {
    guard let pane = state.resetChatPaneToPlaceholder(id: id) else { return }
    persist()
    onPaneChanged?(pane)
  }

  @discardableResult
  func addNewTabPane() -> any Pane {
    let previouslySelected = selectedPane
    let descriptor = state.addNewTabPane()
    persist()
    onPaneChanged?(descriptor)
    onActivated?()
    previouslySelected?.visibilityChanged(false)
    let added = pane(for: descriptor)
    added.visibilityChanged(true)
    return added
  }

  func convertNewTabPane(
    id: UUID,
    to kind: PaneKind,
    chatSessionId: UUID? = nil,
    name: String? = nil,
    pluginId: String? = nil,
    pluginPaneType: String? = nil, publishChange: Bool = true
  ) {
    guard let previous = state.panes.first(where: { $0.id == id }),
      let converted = state.convertNewTabPane(
        id: id, to: kind, sessionId: sessionId,
        chatSessionId: chatSessionId, name: name,
        pluginId: pluginId, pluginPaneType: pluginPaneType
      )
    else { return }
    if Self.requiresNewLivePane(previous: previous, next: converted) {
      discardLivePane(id: id)
    }
    persist()
    if publishChange { onPaneChanged?(converted) }
    pane(for: converted).visibilityChanged(true)
    requestSelectedPaneFocus()
  }

  func canClose(id: UUID) -> Bool {
    guard state.canClosePane(id: id),
      let descriptor = state.panes.first(where: { $0.id == id }),
      isWorkspaceFinalPane?(descriptor) != true
    else { return false }
    switch descriptor.kind {
    case .newTab where state.panes.count == 1:
      return canDissolve?() ?? false
    default:
      return true
    }
  }

  func closePane(id: UUID, activateRemainingPane: Bool = true) {
    guard let descriptor = state.panes.first(where: { $0.id == id }),
      canClose(id: id)
    else { return }
    onPaneWillClose?(descriptor)
    let closing = pane(for: descriptor)
    live[id] = nil
    presentedPaneIDs.remove(id)
    state.closePane(id: id)
    persist()
    Task { await closing.willDelete() }
    onPaneRemoved?(descriptor)
    onPaneClosed?(descriptor)
    if activateRemainingPane, let selected = selectedPane {
      selected.visibilityChanged(true)
    }
  }

  func select(id: UUID) {
    guard state.selectedPaneId != id else { return }
    let previous = state.selectedPaneId.flatMap { live[$0] }
    state.selectPane(id: id)
    persist()
    onActivated?()
    if let previous, previous.id != id {
      previous.visibilityChanged(false)
    }
    requestSelectedPaneFocus()
  }
}
