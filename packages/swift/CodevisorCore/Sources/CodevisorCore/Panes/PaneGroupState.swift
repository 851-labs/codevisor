import Foundation

/// Which input area should hold keyboard focus in a session screen.
public enum SessionFocusTarget: Sendable, Equatable {
  case composer
  case terminal
}

/// The kinds of pane a session's pane groups can host. Future kinds (diff
/// viewers, previews, extensions, ...) add a case here plus a factory branch
/// in the app layer.
public enum PaneKind: String, Codable, Sendable {
  case terminal
  /// A chat session's transcript + composer. Lives in center groups;
  /// closing its tab archives the session.
  case chat
  /// The Chrome-style placeholder spawned when a group's last real pane
  /// closes: the empty state IS a tab (the strip never lies about what's
  /// open), and its page offers what to create. It leaves by conversion —
  /// picking New Chat/New Terminal replaces it in place.
  case newTab
  /// A plugin-contributed webview pane. The descriptor's plugin fields
  /// identify the plugin server and pane type; the app layer renders it
  /// through the server's plugin proxy.
  case plugin
}

/// Which of a session's pane groups a state belongs to: the center group
/// hosting the chat (always visible, fills the page) or the ⌘J bottom panel.
public enum PaneGroupPlacement: String, Sendable {
  case center
  case bottom
}

/// The persisted identity of one pane in a session's pane group. Pure data —
/// live pane objects (surfaces, PTY attachments) are built from this by the
/// app layer.
public struct PaneDescriptorState: Identifiable, Codable, Sendable, Equatable {
  public let id: UUID
  public let kind: PaneKind
  public var name: String
  /// The key the server's PTY manager stores this pane's shell under (sent
  /// as `--session-id` to the terminal proxy). The first pane of a session
  /// uses the bare chat-session UUID so it reattaches to shells created
  /// before panes existed; later panes use "<sessionUuid>:<paneUuid>".
  public let terminalKey: String
  /// Agent-owned background terminals: the pane only ever attaches to a
  /// terminal the server already registered (never spawns a shell), and the
  /// proxy's teardown must not kill the agent's process.
  public let attachOnly: Bool
  /// Chat panes only: the session this pane shows. A chat pane is a
  /// REFERENCE — the server owns the session; closing the pane never
  /// deletes it.
  public var chatSessionId: UUID?
  /// Agent-owned terminals only: the CHAT whose background task streams
  /// here. The workspace's shared panel hosts every chat's task tabs, so
  /// pruning must be owner-scoped — chat B's empty snapshot must never
  /// tear down chat A's dev server.
  public var ownerChatSessionId: UUID?
  /// Plugin panes only: the owner-namespaced plugin id ("owner.name").
  public var pluginId: String?
  /// Plugin panes only: which of the plugin's pane types this renders.
  public var pluginPaneType: String?
  /// Every pane moves between groups alike — tabs are tabs (the only
  /// rule with real stakes is the CLOSE rule: a lone placeholder only
  /// closes when its group can dissolve — see `canClosePane` + the
  /// model's policy). A move is never a close, so nothing gates it.
  public var isMovable: Bool { true }

  public init(
    id: UUID,
    kind: PaneKind,
    name: String,
    terminalKey: String,
    attachOnly: Bool = false,
    chatSessionId: UUID? = nil,
    ownerChatSessionId: UUID? = nil,
    pluginId: String? = nil,
    pluginPaneType: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.terminalKey = terminalKey
    self.attachOnly = attachOnly
    self.chatSessionId = chatSessionId
    self.ownerChatSessionId = ownerChatSessionId
    self.pluginId = pluginId
    self.pluginPaneType = pluginPaneType
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      kind: try container.decode(PaneKind.self, forKey: .kind),
      name: try container.decode(String.self, forKey: .name),
      terminalKey: try container.decode(String.self, forKey: .terminalKey),
      // Panes persisted before agent terminals existed are user shells.
      attachOnly: try container.decodeIfPresent(Bool.self, forKey: .attachOnly) ?? false,
      // Chat panes persisted before workspaces existed learn their
      // session id in the workspace backfill.
      chatSessionId: try container.decodeIfPresent(UUID.self, forKey: .chatSessionId),
      // Agent tabs persisted before owner scoping have no owner; any
      // syncer may manage them.
      ownerChatSessionId: try container.decodeIfPresent(UUID.self, forKey: .ownerChatSessionId),
      // Panes persisted before plugin panes existed carry no plugin
      // payload.
      pluginId: try container.decodeIfPresent(String.self, forKey: .pluginId),
      pluginPaneType: try container.decodeIfPresent(String.self, forKey: .pluginPaneType)
    )
  }
}

/// The per-session bottom pane group's UI state: the panes (tabs), which one
/// is selected, whether the group content is open, and how tall it is. Pure
/// value type so the tab/visibility/resize/focus rules are unit-testable
/// without any AppKit or libghostty involvement. Codable so the pane list
/// survives app restarts (the server keeps each pane's shell alive; stable
/// pane keys are what let us reattach instead of orphaning PTYs).
public struct PaneGroupState: Codable, Sendable, Equatable {
  /// Default content height when first opened.
  public static let defaultHeight: CGFloat = 280
  /// Clamp bounds for the drag-to-resize handle.
  public static let minHeight: CGFloat = 120
  public static let maxHeight: CGFloat = 800

  public var panes: [PaneDescriptorState]
  public var selectedPaneId: UUID?
  public var isVisible: Bool
  public var height: CGFloat

  public init(
    panes: [PaneDescriptorState] = [],
    selectedPaneId: UUID? = nil,
    isVisible: Bool = false,
    height: CGFloat = PaneGroupState.defaultHeight
  ) {
    self.panes = panes
    self.selectedPaneId = selectedPaneId
    self.isVisible = isVisible
    self.height = Self.clampHeight(height)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Element-lenient: a pane persisted by a NEWER build (an unknown
    // future kind) drops alone instead of failing the whole group —
    // the server registry re-materializes anything a downgrade loses.
    let panes = try container.decode([LenientPaneDescriptorState].self, forKey: .panes)
      .compactMap(\.pane)
    let selected = try container.decodeIfPresent(UUID.self, forKey: .selectedPaneId)
    self.init(
      panes: panes,
      // Never restore a selection that doesn't exist anymore.
      selectedPaneId: panes.contains(where: { $0.id == selected }) ? selected : panes.first?.id,
      isVisible: try container.decode(Bool.self, forKey: .isVisible),
      height: try container.decode(CGFloat.self, forKey: .height)
    )
  }

  /// Legacy pre-workspace bottom-panel state. New workspaces start with an
  /// empty bottom group and create their first terminal when the panel is
  /// opened. This factory remains for decoding/migration tests: its bare
  /// session key reattaches shells created before pane identities existed.
  public static func initial(sessionId: UUID) -> PaneGroupState {
    let pane = PaneDescriptorState(
      id: UUID(),
      kind: .terminal,
      name: "Terminal 1",
      terminalKey: sessionId.uuidString
    )
    return PaneGroupState(panes: [pane], selectedPaneId: pane.id)
  }

  /// The state a session's center group starts with: the chat pane, bound
  /// to its session (an unbound chat pane is a DRAFT — see addChatPane),
  /// always visible (the center group has no collapsed state — it IS the
  /// page).
  public static func centerInitial(sessionId: UUID) -> PaneGroupState {
    let chat = PaneDescriptorState(
      id: UUID(),
      kind: .chat,
      name: "Chat",
      terminalKey: sessionId.uuidString,
      chatSessionId: sessionId
    )
    return PaneGroupState(panes: [chat], selectedPaneId: chat.id, isVisible: true)
  }

  public var selectedPane: PaneDescriptorState? {
    panes.first { $0.id == selectedPaneId }
  }

  /// Adopts the pane identities/content produced by workspace sync while
  /// retaining this client's presentation state. Selection, visibility,
  /// and height are device-local; the incoming state is authoritative only
  /// for which shared panes exist and what each pane renders.
  ///
  /// The existing selection survives when its pane still exists. If sync
  /// removed it, the repository's repaired selection is preferred before
  /// falling back to the first remaining pane.
  @discardableResult
  public mutating func reconcilePaneDescriptors(from incoming: PaneGroupState) -> Bool {
    let previousPanes = panes
    let previousSelection = selectedPaneId
    let selectionIsValid =
      previousSelection.map { selected in
        previousPanes.contains(where: { $0.id == selected })
      } ?? previousPanes.isEmpty
    guard previousPanes != incoming.panes || !selectionIsValid else { return false }

    panes = incoming.panes
    if let previousSelection,
      panes.contains(where: { $0.id == previousSelection })
    {
      selectedPaneId = previousSelection
    } else if let incomingSelection = incoming.selectedPaneId,
      panes.contains(where: { $0.id == incomingSelection })
    {
      selectedPaneId = incomingSelection
    } else {
      selectedPaneId = panes.first?.id
    }
    return previousPanes != panes || previousSelection != selectedPaneId
  }

  /// Toggles content visibility and returns the area that should receive
  /// focus: opening focuses the selected pane, closing returns focus to the
  /// composer.
  @discardableResult
  public mutating func toggle() -> SessionFocusTarget {
    isVisible.toggle()
    return isVisible ? .terminal : .composer
  }

  /// Sets the content height, clamped to `[minHeight, maxHeight]`.
  public mutating func setHeight(_ newHeight: CGFloat) {
    height = Self.clampHeight(newHeight)
  }

  /// Appends a new terminal pane named "Terminal N" (N = highest existing
  /// numeric suffix + 1), selects it, and opens the group. The shell spawns
  /// in the workspace's working directory (the anchor session's cwd).
  @discardableResult
  public mutating func addTerminalPane(sessionId: UUID) -> PaneDescriptorState {
    let paneId = UUID()
    let pane = PaneDescriptorState(
      id: paneId,
      kind: .terminal,
      name: Self.nextTerminalName(existing: panes.map(\.name)),
      terminalKey: "\(sessionId.uuidString):\(paneId.uuidString)"
    )
    panes.append(pane)
    selectedPaneId = pane.id
    isVisible = true
    return pane
  }

  /// Ensures a tab exists for an agent-owned background terminal (keyed by
  /// the task's `terminalKey`). Unlike `addTerminalPane` this never steals
  /// selection or opens the group — the tab appearing in the always-visible
  /// bar IS the notification. Returns the existing pane when one is already
  /// attached to that terminal.
  @discardableResult
  public mutating func ensureAgentTerminalPane(
    name: String,
    terminalKey: String,
    ownerChatSessionId: UUID? = nil
  ) -> PaneDescriptorState {
    if let existing = panes.first(where: { $0.terminalKey == terminalKey }) {
      return existing
    }
    let pane = PaneDescriptorState(
      id: UUID(),
      kind: .terminal,
      name: name,
      terminalKey: terminalKey,
      attachOnly: true,
      ownerChatSessionId: ownerChatSessionId
    )
    panes.append(pane)
    if selectedPaneId == nil {
      selectedPaneId = pane.id
    }
    return pane
  }

  /// Appends a chat pane and selects it. A nil session id is a DRAFT: the
  /// pane hosts the new-chat composer and binds to a session on first send.
  @discardableResult
  public mutating func addChatPane(
    sessionId: UUID? = nil,
    name: String = "New Chat"
  ) -> PaneDescriptorState {
    let paneId = UUID()
    let pane = PaneDescriptorState(
      id: paneId,
      kind: .chat,
      name: name,
      terminalKey: paneId.uuidString,
      chatSessionId: sessionId
    )
    panes.append(pane)
    selectedPaneId = pane.id
    isVisible = true
    return pane
  }

  /// Appends the Chrome-style "New tab" placeholder and selects it —
  /// spawned when a group's last real pane closes, so the strip always
  /// shows at least one tab. Its page offers what to create; everything
  /// opens in the workspace's working directory.
  @discardableResult
  public mutating func addNewTabPane() -> PaneDescriptorState {
    let paneId = UUID()
    let pane = PaneDescriptorState(
      id: paneId,
      kind: .newTab,
      name: "New tab",
      terminalKey: paneId.uuidString
    )
    panes.append(pane)
    selectedPaneId = pane.id
    isVisible = true
    return pane
  }

  /// Replaces a New Tab placeholder with a real pane IN PLACE (same slot;
  /// selection follows): a terminal, or a chat — established when
  /// `chatSessionId` is provided (the session was created eagerly), a
  /// draft that binds on first send otherwise. Returns nil when the pane
  /// isn't a placeholder (or the target kind is another placeholder).
  @discardableResult
  public mutating func convertNewTabPane(
    id: UUID,
    to kind: PaneKind,
    sessionId: UUID,
    chatSessionId: UUID? = nil,
    name: String? = nil,
    pluginId: String? = nil,
    pluginPaneType: String? = nil
  ) -> PaneDescriptorState? {
    guard let index = panes.firstIndex(where: { $0.id == id }),
      panes[index].kind == .newTab
    else { return nil }
    let paneId = id
    let pane: PaneDescriptorState
    switch kind {
    case .terminal:
      pane = PaneDescriptorState(
        id: paneId,
        kind: .terminal,
        name: Self.nextTerminalName(existing: panes.map(\.name)),
        terminalKey: "\(sessionId.uuidString):\(paneId.uuidString)"
      )
    case .chat:
      pane = PaneDescriptorState(
        id: paneId,
        kind: .chat,
        name: name ?? "New Chat",
        terminalKey: paneId.uuidString,
        chatSessionId: chatSessionId
      )
    case .plugin:
      guard
        let converted = Self.pluginPane(
          id: paneId, name: name, pluginId: pluginId,
          pluginPaneType: pluginPaneType
        )
      else { return nil }
      pane = converted
    case .newTab:
      return nil
    }
    panes[index] = pane
    if selectedPaneId == id {
      selectedPaneId = pane.id
    }
    return pane
  }

  /// Reverts a chat pane to an unbound DRAFT (its session was deleted —
  /// e.g. a failed first-send setup tore the record down). The pane and
  /// its composer stay; only the dangling reference goes.
  public mutating func unbindChatPane(paneId: UUID) {
    guard let index = panes.firstIndex(where: { $0.id == paneId }),
      panes[index].kind == .chat
    else { return }
    panes[index].chatSessionId = nil
    panes[index].name = "New Chat"
  }

  /// Replaces a chat pane whose session no longer exists with a New Tab
  /// placeholder IN PLACE (same slot; selection follows) — the dead-end
  /// "chat no longer exists" state becomes a fresh start.
  @discardableResult
  public mutating func resetChatPaneToPlaceholder(id: UUID) -> PaneDescriptorState? {
    guard let index = panes.firstIndex(where: { $0.id == id }),
      panes[index].kind == .chat
    else { return nil }
    return replacePaneWithNewTab(id: id)
  }

  /// Converts any renderer into a New Tab while preserving the server-owned
  /// pane identity. Used for an optimistic final-pane close; the server
  /// performs and confirms the same transition atomically.
  @discardableResult
  public mutating func replacePaneWithNewTab(id: UUID) -> PaneDescriptorState? {
    guard let index = panes.firstIndex(where: { $0.id == id }) else { return nil }
    let pane = PaneDescriptorState(
      id: id,
      kind: .newTab,
      name: "New tab",
      terminalKey: id.uuidString
    )
    panes[index] = pane
    if selectedPaneId == id {
      selectedPaneId = pane.id
    }
    return pane
  }

  /// Binds a draft chat pane to its just-created session (first send).
  public mutating func assignChatSession(paneId: UUID, sessionId: UUID, name: String) {
    guard let index = panes.firstIndex(where: { $0.id == paneId }),
      panes[index].kind == .chat
    else { return }
    panes[index].chatSessionId = sessionId
    panes[index].name = name
  }

  /// Whether a pane's tab may close, by GROUP-LOCAL rules: every existing
  /// pane may. The rules that need cross-group sight live in the owning
  /// model's policies: the workspace keeps at least one established chat
  /// (its anchor), and a LONE New Tab placeholder closes only when its
  /// group can dissolve (in the workspace's last group, closing it would
  /// just respawn it).
  public func canClosePane(id: UUID) -> Bool {
    panes.contains { $0.id == id }
  }

  /// Inserts an existing pane (a cross-group transfer) at `index` (clamped),
  /// selects it, and opens the group.
  public mutating func insertPane(_ pane: PaneDescriptorState, at index: Int) {
    guard !panes.contains(where: { $0.id == pane.id }) else { return }
    panes.insert(pane, at: min(max(index, 0), panes.count))
    selectedPaneId = pane.id
    isVisible = true
  }

  /// Removes a pane (no-op when `canClosePane` forbids it). If it was
  /// selected, selection moves to its right neighbor (or the new last
  /// pane). Closing the last pane hides the group.
  @discardableResult
  public mutating func closePane(id: UUID) -> PaneDescriptorState? {
    guard canClosePane(id: id) else { return nil }
    return removePane(id: id)
  }

  /// Removes a pane WITHOUT consulting the close rules — the extraction
  /// half of a cross-group MOVE (a move isn't a close: a lone New Tab
  /// placeholder may not close, but it may leave for another group).
  /// Selection moves like closePane's.
  @discardableResult
  public mutating func removePane(id: UUID) -> PaneDescriptorState? {
    guard let index = panes.firstIndex(where: { $0.id == id }) else { return nil }
    let removed = panes.remove(at: index)
    if panes.isEmpty {
      selectedPaneId = nil
      isVisible = false
    } else if selectedPaneId == id {
      selectedPaneId = panes[min(index, panes.count - 1)].id
    }
    return removed
  }

  /// Moves the pane with `id` into the slot currently occupied by the pane
  /// with `targetId` (drag-to-reorder swap-flow semantics: the dragged tab
  /// takes the hovered tab's position). Selection follows the pane.
  public mutating func movePane(id: UUID, onto targetId: UUID) {
    guard id != targetId,
      let from = panes.firstIndex(where: { $0.id == id }),
      let target = panes.firstIndex(where: { $0.id == targetId })
    else { return }
    let pane = panes.remove(at: from)
    // After removal the same index lands the pane after the target when
    // dragging right and before it when dragging left — both take the
    // target's visual slot.
    panes.insert(pane, at: target)
  }

  /// Selects a pane. Selecting while collapsed also opens the group (tab
  /// clicks in the always-visible bar should reveal their content).
  public mutating func selectPane(id: UUID) {
    guard panes.contains(where: { $0.id == id }) else { return }
    selectedPaneId = id
    isVisible = true
  }

  /// "Terminal N" with N one past the highest existing "Terminal <int>"
  /// suffix (so after closing "Terminal 2" of [1, 2], the next add is
  /// "Terminal 2" again; with [1, 3] it is "Terminal 4").
  static func nextTerminalName(existing: [String]) -> String {
    let highest =
      existing
      .compactMap { name -> Int? in
        guard name.hasPrefix("Terminal ") else { return nil }
        return Int(name.dropFirst("Terminal ".count))
      }
      .max() ?? 0
    return "Terminal \(highest + 1)"
  }

  private static func clampHeight(_ value: CGFloat) -> CGFloat {
    min(max(value, minHeight), maxHeight)
  }
}
