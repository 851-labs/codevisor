import Foundation
import Observation
import SwiftUI
import CodevisorCore

extension PaneGroupModel {
  // MARK: - Operations

  /// Adds a terminal tab, selects it, opens the group, and returns the live
  /// pane (so callers can focus it). The shell opens in the workspace's
  /// working directory.
  @discardableResult
  func addTerminalPane() -> any Pane {
    let previouslySelected = selectedPane
    let descriptor = state.addTerminalPane(sessionId: sessionId)
    persist()
    onPaneChanged?(descriptor)
    onActivated?()
    previouslySelected?.visibilityChanged(false)
    let added = pane(for: descriptor)
    added.visibilityChanged(true)
    return added
  }

  /// Adds a DRAFT chat tab (in-pane new-chat composer; binds to a session
  /// on first send), selects it.
  @discardableResult
  func addChatPane() -> any Pane {
    let previouslySelected = selectedPane
    let descriptor = state.addChatPane()
    persist()
    onPaneChanged?(descriptor)
    onActivated?()
    previouslySelected?.visibilityChanged(false)
    let added = pane(for: descriptor)
    added.visibilityChanged(true)
    return added
  }

  /// Binds a draft chat pane to its just-created session (first send).
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

  /// Reverts a chat pane to an unbound draft (its session was deleted by
  /// a failed first-send setup).
  func unbindChatPane(paneId: UUID) {
    state.unbindChatPane(paneId: paneId)
    persist()
    if let pane = state.panes.first(where: { $0.id == paneId }) { onPaneChanged?(pane) }
  }

  /// Replaces a dead chat pane (session gone) with a New Tab placeholder.
  func resetChatPaneToPlaceholder(id: UUID) {
    guard let pane = state.resetChatPaneToPlaceholder(id: id) else { return }
    persist()
    onPaneChanged?(pane)
  }

  /// Adds the "New tab" placeholder — spawned by the container when this
  /// group's last real pane closes and the group is the workspace's last.
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

  /// Converts a New Tab placeholder into a real pane in place (the
  /// page's New Chat / New Terminal choices). Chats pass the eagerly
  /// created session so the pane is established from birth.
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

  /// Whether a tab may close: the group-local state rules plus the
  /// container's workspace-wide policy (lone-placeholder dissolve). Chats
  /// close like any tab — closing archives the session while preserving
  /// the workspace.
  func canClose(id: UUID) -> Bool {
    guard state.canClosePane(id: id),
      let descriptor = state.panes.first(where: { $0.id == id })
    else { return false }
    switch descriptor.kind {
    case .newTab where state.panes.count == 1:
      // A lone placeholder IS its group's empty state: closing it
      // dissolves the group — allowed only while other groups exist.
      return canDissolve?() ?? false
    default:
      return true
    }
  }

  /// Closes a tab: fires the pane's willDelete hook (kills its backing
  /// resources) and moves selection per the state rules. No-op when the
  /// rules forbid closing (the workspace's anchoring chat).
  func closePane(id: UUID, activateRemainingPane: Bool = true) {
    guard let descriptor = state.panes.first(where: { $0.id == id }),
      canClose(id: id)
    else { return }
    // Instantiate if needed: a never-shown pane may still own a server
    // shell from a previous app run that willDelete must clean up.
    let closing = pane(for: descriptor)
    live[id] = nil
    presentedPaneIDs.remove(id)
    let replacement =
      shouldReplaceClosedPaneWithNewTab?(descriptor) == true
      ? state.replacePaneWithNewTab(id: id)
      : nil
    if replacement != nil {
      if activateRemainingPane { requestBackgroundFocus?() }
    } else {
      state.closePane(id: id)
    }
    persist()
    Task { await closing.willDelete() }
    onPaneRemoved?(descriptor, replacement)
    onPaneClosed?(descriptor)
    if activateRemainingPane, let selected = selectedPane {
      selected.visibilityChanged(true)
    }
  }

  /// Selects a pane and requests focus after its content mounts.
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

  // MARK: - Cross-group transfer

  /// Removes a pane for adoption by another group, WITHOUT firing willDelete
  /// (its backing shell keeps running — the pane is moving, not dying).
  /// Returns the descriptor plus the live pane (nil if never instantiated).
  /// Extraction bypasses the CLOSE rules — a move isn't a close (the
  /// anchor chat and a lone New Tab placeholder can't close, but they
  /// move freely; closePane would silently no-op and the pane would land
  /// in BOTH groups).
  func extractPane(id: UUID) -> (descriptor: PaneDescriptorState, live: (any Pane)?)? {
    guard let descriptor = state.panes.first(where: { $0.id == id }) else { return nil }
    let livePane = live.removeValue(forKey: id)
    state.removePane(id: id)
    persist()
    if let selected = selectedPane {
      selected.visibilityChanged(true)
    }
    return (descriptor, livePane)
  }

  /// Adopts a pane extracted from another group at `index` (clamped),
  /// selecting it. The live pane object carries over so its content (the
  /// terminal's cached surface) survives the move without reattaching.
  func adoptPane(
    _ descriptor: PaneDescriptorState,
    live livePane: (any Pane)?,
    at index: Int
  ) {
    let previous = selectedPane
    state.insertPane(descriptor, at: index)
    persist()
    onActivated?()
    if let livePane {
      livePane.onGroupCommand = { [weak self] command in self?.handleCommand(command) }
      livePane.onFocusChanged = { [weak self] focused in
        self?.paneFocusChanged(focused: focused)
      }
      // A carried ChatPane host still resolves content through its
      // OLD group's model — rebind it here or it renders nothing.
      if let chat = livePane as? ChatPane {
        wireChatHost(chat, paneId: descriptor.id)
      }
      if let browser = livePane as? BrowserPane { wireBrowser(browser) }
      live[descriptor.id] = livePane
    }
    if let previous, previous.id != descriptor.id {
      previous.visibilityChanged(false)
    }
    selectedPane?.visibilityChanged(true)
  }
}
