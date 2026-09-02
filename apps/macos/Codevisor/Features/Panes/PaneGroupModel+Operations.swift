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
    DispatchQueue.main.async { [weak self] in self?.focusSelectedPane() }
  }

  /// Syncs the agent's background-task snapshot into tabs: ensures a pane
  /// exists per task terminal, never stealing selection or opening the
  /// group — the tab appearing in the always-visible bar is the affordance.
  /// A tab lives exactly as long as its task: when a task leaves ITS
  /// OWNING CHAT's snapshot (the agent killed it, or it finished), its tab
  /// goes with it. The workspace panel hosts every chat's task tabs, so
  /// each chat syncs only its own: `owner` scopes both adds and prunes —
  /// chat B's empty snapshot must never tear down chat A's dev server.
  /// `pruneEnded` is false until the owner's first snapshot arrives — an
  /// empty task list before replay means "unknown", not "everything
  /// ended". Tabs persisted before owner scoping (nil owner) are adopted
  /// by the first owner whose live tasks match; a remaining nil-owned
  /// tab is left alone (it still attaches; closing it is manual).
  func syncAgentTerminals(
    _ tasks: [(terminalKey: String, name: String)],
    owner: UUID,
    pruneEnded: Bool
  ) {
    var changed = false
    for task in tasks {
      if let index = state.panes.firstIndex(where: { $0.terminalKey == task.terminalKey }) {
        // Legacy tab for a live task: adopt it.
        if state.panes[index].attachOnly, state.panes[index].ownerChatSessionId == nil {
          state.panes[index].ownerChatSessionId = owner
          changed = true
        }
        continue
      }
      state.ensureAgentTerminalPane(
        name: task.name,
        terminalKey: task.terminalKey,
        ownerChatSessionId: owner
      )
      if let pane = state.panes.first(where: { $0.terminalKey == task.terminalKey }) {
        onPaneChanged?(pane)
      }
      changed = true
    }
    if changed {
      persist()
    }
    guard pruneEnded else { return }
    let liveKeys = Set(tasks.map(\.terminalKey))
    for pane in state.panes
    where pane.attachOnly
      && pane.ownerChatSessionId == owner
      && !liveKeys.contains(pane.terminalKey)
    {
      // closePane also deletes the server-side terminal (a no-op when
      // the kill already removed it).
      closePane(id: pane.id)
    }
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
  func closePane(id: UUID) {
    guard let descriptor = state.panes.first(where: { $0.id == id }),
      canClose(id: id)
    else { return }
    // Instantiate if needed: a never-shown pane may still own a server
    // shell from a previous app run that willDelete must clean up.
    let closing = pane(for: descriptor)
    live[id] = nil
    let replacement =
      shouldReplaceClosedPaneWithNewTab?(descriptor) == true
      ? state.replacePaneWithNewTab(id: id)
      : nil
    if replacement != nil {
      paneFocusChanged(id: id, focused: false)
      requestBackgroundFocus?()
    } else if state.panes.count == 1 {
      // Closing the last tab also collapses the group. Suppress the
      // removal/collapse animations: the tab's exit transition would
      // otherwise replay in the already-collapsed bar (flicker).
      var transaction = Transaction()
      transaction.disablesAnimations = true
      _ = withTransaction(transaction) {
        state.closePane(id: id)
      }
    } else {
      state.closePane(id: id)
    }
    persist()
    Task { await closing.willDelete() }
    onPaneRemoved?(descriptor, replacement)
    onPaneClosed?(descriptor)
    if state.isVisible, let selected = selectedPane {
      selected.visibilityChanged(true)
    }
  }

  /// Selects a tab; also expands the group when collapsed (tab clicks in
  /// the always-visible bar reveal their content).
  func select(id: UUID) {
    guard state.selectedPaneId != id || !state.isVisible else { return }
    let previous = state.isVisible ? selectedPane : nil
    state.selectPane(id: id)
    persist()
    onActivated?()
    if let previous, previous.id != id {
      previous.visibilityChanged(false)
    }
    selectedPane?.visibilityChanged(true)
  }

  /// Toggles the group's content. Opening with zero panes creates
  /// "Terminal 1". Returns the area that should receive focus.
  @discardableResult
  func toggle() -> SessionFocusTarget {
    if !state.isVisible && state.panes.isEmpty {
      addTerminalPane()
      return .terminal
    }
    let target = state.toggle()
    persist()
    selectedPane?.visibilityChanged(state.isVisible)
    return target
  }

  /// Drag-to-reorder: moves the dragged pane to the hovered tab's slot.
  func movePane(id: UUID, onto targetId: UUID) {
    state.movePane(id: id, onto: targetId)
    persist()
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
    paneFocusChanged(id: id, focused: false)
    state.removePane(id: id)
    persist()
    if state.isVisible, let selected = selectedPane {
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
    let previous = state.isVisible ? selectedPane : nil
    state.insertPane(descriptor, at: index)
    persist()
    onActivated?()
    if let livePane {
      livePane.onGroupCommand = { [weak self] command in self?.handleCommand(command) }
      livePane.onFocusChanged = { [weak self] focused in
        self?.paneFocusChanged(id: descriptor.id, focused: focused)
      }
      // A carried ChatPane host still resolves content through its
      // OLD group's model — rebind it here or it renders nothing.
      if let chat = livePane as? ChatPane {
        wireChatHost(chat, paneId: descriptor.id)
      }
      live[descriptor.id] = livePane
    }
    if let previous, previous.id != descriptor.id {
      previous.visibilityChanged(false)
    }
    selectedPane?.visibilityChanged(true)
  }
}
