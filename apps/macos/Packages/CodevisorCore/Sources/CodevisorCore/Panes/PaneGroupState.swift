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
    /// The session's chat itself: transcript + composer. Lives in the center
    /// group; exactly one per session, not closable.
    case chat
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

    /// Whether the user can close (or move between groups) this pane. The
    /// chat pane is the session itself: no ✕, no drag-out.
    public var isClosable: Bool { kind != .chat }

    public init(id: UUID, kind: PaneKind, name: String, terminalKey: String, attachOnly: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.terminalKey = terminalKey
        self.attachOnly = attachOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(PaneKind.self, forKey: .kind),
            name: try container.decode(String.self, forKey: .name),
            terminalKey: try container.decode(String.self, forKey: .terminalKey),
            // Panes persisted before agent terminals existed are user shells.
            attachOnly: try container.decodeIfPresent(Bool.self, forKey: .attachOnly) ?? false
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
        let panes = try container.decode([PaneDescriptorState].self, forKey: .panes)
        let selected = try container.decodeIfPresent(UUID.self, forKey: .selectedPaneId)
        self.init(
            panes: panes,
            // Never restore a selection that doesn't exist anymore.
            selectedPaneId: panes.contains(where: { $0.id == selected }) ? selected : panes.first?.id,
            isVisible: try container.decode(Bool.self, forKey: .isVisible),
            height: try container.decode(CGFloat.self, forKey: .height)
        )
    }

    /// The state a session's bottom panel starts with: one terminal pane
    /// whose key is the bare session UUID (migration: reattaches shells
    /// created before the pane-group era, since the server never reaps PTYs).
    public static func initial(sessionId: UUID) -> PaneGroupState {
        let pane = PaneDescriptorState(
            id: UUID(),
            kind: .terminal,
            name: "Terminal 1",
            terminalKey: sessionId.uuidString
        )
        return PaneGroupState(panes: [pane], selectedPaneId: pane.id)
    }

    /// The state a session's center group starts with: the chat pane, always
    /// visible (the center group has no collapsed state — it IS the page).
    public static func centerInitial(sessionId: UUID) -> PaneGroupState {
        let chat = PaneDescriptorState(
            id: UUID(),
            kind: .chat,
            name: "Chat",
            terminalKey: sessionId.uuidString
        )
        return PaneGroupState(panes: [chat], selectedPaneId: chat.id, isVisible: true)
    }

    public var selectedPane: PaneDescriptorState? {
        panes.first { $0.id == selectedPaneId }
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
    /// numeric suffix + 1), selects it, and opens the group.
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
    public mutating func ensureAgentTerminalPane(name: String, terminalKey: String) -> PaneDescriptorState {
        if let existing = panes.first(where: { $0.terminalKey == terminalKey }) {
            return existing
        }
        let pane = PaneDescriptorState(
            id: UUID(),
            kind: .terminal,
            name: name,
            terminalKey: terminalKey,
            attachOnly: true
        )
        panes.append(pane)
        if selectedPaneId == nil {
            selectedPaneId = pane.id
        }
        return pane
    }

    /// Inserts an existing pane (a cross-group transfer) at `index` (clamped),
    /// selects it, and opens the group.
    public mutating func insertPane(_ pane: PaneDescriptorState, at index: Int) {
        guard !panes.contains(where: { $0.id == pane.id }) else { return }
        panes.insert(pane, at: min(max(index, 0), panes.count))
        selectedPaneId = pane.id
        isVisible = true
    }

    /// Removes a pane (no-op for non-closable panes — the chat pane cannot
    /// leave its group). If it was selected, selection moves to its right
    /// neighbor (or the new last pane). Closing the last pane hides the group.
    @discardableResult
    public mutating func closePane(id: UUID) -> PaneDescriptorState? {
        guard let index = panes.firstIndex(where: { $0.id == id }),
              panes[index].isClosable else { return nil }
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
              let target = panes.firstIndex(where: { $0.id == targetId }) else { return }
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
        let highest = existing
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
