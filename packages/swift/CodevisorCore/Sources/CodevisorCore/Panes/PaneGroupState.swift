import Foundation

public struct PaneGroupState: Codable, Sendable, Equatable {
  public var panes: [PaneDescriptorState]
  public var selectedPaneId: UUID?

  public init(
    panes: [PaneDescriptorState] = [],
    selectedPaneId: UUID? = nil
  ) {
    self.panes = panes
    self.selectedPaneId = selectedPaneId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let panes = try container.decode([LenientPaneDescriptorState].self, forKey: .panes)
      .compactMap(\.pane)
    let selected = try container.decodeIfPresent(UUID.self, forKey: .selectedPaneId)
    self.init(
      panes: panes,
      selectedPaneId: panes.contains(where: { $0.id == selected }) ? selected : panes.first?.id
    )
  }

  public static func centerInitialWithoutChat() -> PaneGroupState {
    var state = PaneGroupState()
    state.addNewTabPane()
    return state
  }

  public static func centerInitial(sessionId: UUID, paneId: UUID = UUID()) -> PaneGroupState {
    let chat = PaneDescriptorState(
      id: paneId,
      kind: .chat,
      name: "Chat",
      terminalKey: sessionId.uuidString,
      chatSessionId: sessionId
    )
    return PaneGroupState(panes: [chat], selectedPaneId: chat.id)
  }

  public var selectedPane: PaneDescriptorState? {
    panes.first { $0.id == selectedPaneId }
  }

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

  @discardableResult
  public mutating func addTerminalPane(sessionId: UUID) -> PaneDescriptorState {
    let paneId = UUID()
    let pane = PaneDescriptorState(
      id: paneId,
      kind: .terminal,
      name: PaneDescriptorState.defaultTerminalName,
      terminalKey: "\(sessionId.uuidString):\(paneId.uuidString)"
    )
    panes.append(pane)
    selectedPaneId = pane.id
    return pane
  }

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
    return pane
  }

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
    return pane
  }

  @discardableResult
  public mutating func convertNewTabPane(
    id: UUID,
    to kind: PaneKind,
    sessionId: UUID?,
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
      guard let sessionId else { return nil }
      pane = PaneDescriptorState(
        id: paneId,
        kind: .terminal,
        name: PaneDescriptorState.defaultTerminalName,
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
    case .browser:
      pane = PaneDescriptorState(
        id: paneId, kind: .browser, name: "Browser",
        terminalKey: paneId.uuidString, browserURL: "https://www.google.com/")
    case .screenSharing:
      pane = PaneDescriptorState(
        id: paneId, kind: .screenSharing, name: "Screen Sharing",
        terminalKey: paneId.uuidString, screenSharing: ScreenSharingPanePreferences())
    case .review:
      pane = PaneDescriptorState(
        id: paneId, kind: .review, name: "Review Changes",
        terminalKey: paneId.uuidString, review: ReviewPanePreferences())
    case .simulator:
      pane = PaneDescriptorState(
        id: paneId, kind: .simulator, name: name ?? "Simulator",
        terminalKey: paneId.uuidString, simulator: SimulatorPanePreferences())
    case .newTab, .document, .subagent:
      return nil
    }
    panes[index] = pane
    if selectedPaneId == id {
      selectedPaneId = pane.id
    }
    return pane
  }

  public mutating func unbindChatPane(paneId: UUID) {
    guard let index = panes.firstIndex(where: { $0.id == paneId }),
      panes[index].kind == .chat
    else { return }
    panes[index].chatSessionId = nil
    panes[index].name = "New Chat"
  }

  @discardableResult
  public mutating func resetChatPaneToPlaceholder(id: UUID) -> PaneDescriptorState? {
    guard let index = panes.firstIndex(where: { $0.id == id }),
      panes[index].kind == .chat
    else { return nil }
    return replacePaneWithNewTab(id: id)
  }

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

  public mutating func assignChatSession(paneId: UUID, sessionId: UUID, name: String) {
    guard let index = panes.firstIndex(where: { $0.id == paneId }),
      panes[index].kind == .chat
    else { return }
    panes[index].chatSessionId = sessionId
    panes[index].name = name
  }

  public func canClosePane(id: UUID) -> Bool {
    panes.contains { $0.id == id }
  }

  @discardableResult
  public mutating func closePane(id: UUID) -> PaneDescriptorState? {
    guard canClosePane(id: id) else { return nil }
    return removePane(id: id)
  }

  @discardableResult
  public mutating func removePane(id: UUID) -> PaneDescriptorState? {
    guard let index = panes.firstIndex(where: { $0.id == id }) else { return nil }
    let removed = panes.remove(at: index)
    if selectedPaneId == id {
      selectedPaneId = Self.replacementSelection(afterRemovingAt: index, from: panes)
    }
    return removed
  }

  static func replacementSelection(
    afterRemovingAt index: Int, from panes: [PaneDescriptorState]
  ) -> UUID? {
    guard !panes.isEmpty else { return nil }
    return (index > 0 ? panes[index - 1] : panes[0]).id
  }

  public mutating func selectPane(id: UUID) {
    guard panes.contains(where: { $0.id == id }) else { return }
    selectedPaneId = id
  }

  static func pluginPane(
    id: UUID,
    name: String?,
    pluginId: String?,
    pluginPaneType: String?
  ) -> PaneDescriptorState? {
    guard let pluginId, !pluginId.isEmpty, let pluginPaneType, !pluginPaneType.isEmpty
    else { return nil }
    return PaneDescriptorState(
      id: id,
      kind: .plugin,
      name: name ?? "Plugin",
      terminalKey: id.uuidString,
      pluginId: pluginId,
      pluginPaneType: pluginPaneType
    )
  }

  public func pane(steppingFrom paneId: UUID, by offset: Int) -> PaneDescriptorState? {
    guard let index = panes.firstIndex(where: { $0.id == paneId }),
      let target = Self.wrappedIndex(index, by: offset, count: panes.count)
    else { return nil }
    return panes[target]
  }

  private static func wrappedIndex(_ index: Int, by offset: Int, count: Int) -> Int? {
    guard count > 1 else { return nil }
    return ((index + offset) % count + count) % count
  }
}

struct LenientPaneDescriptorState: Decodable {
  let pane: PaneDescriptorState?

  init(from decoder: Decoder) throws {
    pane = try? PaneDescriptorState(from: decoder)
  }
}
