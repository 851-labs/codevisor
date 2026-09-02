//  The live pane group for one chat session: owns the persisted PaneGroupState
//  (tabs/selection/visibility/height), lazily instantiates live Pane objects
//  from their descriptors, fires the pane lifecycle hooks, and persists every
//  state mutation.

import Foundation
import Observation
import SwiftUI
import CodevisorCore

@MainActor
@Observable
final class PaneGroupModel: Identifiable {
    let sessionId: UUID
    /// Which of the session's groups this is: the center group hosting the
    /// chat, or the ⌘J bottom panel.
    let placement: PaneGroupPlacement
    var state: PaneGroupState
    /// Whether keyboard focus is inside one of this group's panes (a focused
    /// terminal surface). Drives the bar's ⌘N shortcut hints.
    private(set) var hasFocusedPane = false
    /// Builds a chat pane's content from its LIVE descriptor (drafts render
    /// the new-chat composer; established chats their session's ChatScreen).
    /// Wired by the container at model creation — before anything renders —
    /// so it needs no observability (and is set during body evaluation,
    /// where observable mutation would be illegal).
    @ObservationIgnored var chatContent: ((PaneDescriptorState) -> AnyView)?

    @ObservationIgnored private var focusedPaneIds: Set<UUID> = []
    @ObservationIgnored var live: [UUID: any Pane] = [:]
    @ObservationIgnored private let repository: any PaneGroupRepository
    @ObservationIgnored private let makeContext: (PaneDescriptorState) -> PaneContext
    @ObservationIgnored let pluginIconClient: (any CodevisorServerClienting)?
    @ObservationIgnored let pluginIconCacheNamespace: String
    /// Set by the session screen: performs the panel toggle with proper focus
    /// handoff (the screen owns the composer/terminal focus controller).
    @ObservationIgnored var requestToggle: (() -> Void)?
    /// Set by the session screen: moves keyboard focus to the composer (used
    /// when closing the last tab collapses the group, and as the chat pane's
    /// focus target).
    @ObservationIgnored var requestComposerFocus: (() -> Void)?
    /// Set by the session screen: clears focus from another pane without
    /// inventing an input target for content that has none (currently the
    /// New Tab placeholder). This keeps a hidden terminal from remaining the
    /// first responder after its tab is replaced by a passive page.
    @ObservationIgnored var requestBackgroundFocus: (() -> Void)?
    /// Fired after a tab closes (the descriptor already removed) — the app
    /// layer cleans up per-pane resources (draft controllers) and archives
    /// closed established chats' sessions.
    @ObservationIgnored var onPaneClosed: ((PaneDescriptorState) -> Void)?
    /// Shared identity changed (create/convert/rename/bind). Layout persistence
    /// stays local; the owning store mirrors this descriptor to the server.
    @ObservationIgnored var onPaneChanged: ((PaneDescriptorState) -> Void)?
    /// Separate from `onPaneClosed`, which containers replace with navigation
    /// policy. A non-nil replacement means this was the workspace's final
    /// pane and the same shared identity was optimistically reset to New Tab.
    @ObservationIgnored var onPaneRemoved: ((PaneDescriptorState, PaneDescriptorState?) -> Void)?
    /// Workspace-wide final-pane policy supplied by the owning store.
    @ObservationIgnored var shouldReplaceClosedPaneWithNewTab: ((PaneDescriptorState) -> Bool)?
    /// Whether this group may dissolve out of the workspace (i.e. other
    /// groups exist). Gates closing a LONE New Tab placeholder — its close
    /// IS a dissolve, and in the workspace's last group it would just
    /// respawn. Nil (previews, bottom panel) means no.
    @ObservationIgnored var canDissolve: (() -> Bool)?
    /// This group's identity for cross-group drops (bottom panel or a
    /// center-tree leaf). Set by the store at creation; nil in previews.
    @ObservationIgnored var dropRef: PaneGroupRef?
    /// Fired whenever the user acts IN this group (tab click, pane focus,
    /// new tab, adopted drop) — the container tracks the workspace's ACTIVE
    /// group with it, which is where keyboard tab commands route.
    @ObservationIgnored var onActivated: (() -> Void)?
    /// Center leaves hand workspace-level tab/split commands to their
    /// container. Returning true means the command was consumed. This is
    /// ignored for bottom-panel models so their shortcuts always remain local.
    @ObservationIgnored var workspaceCommandHandler: ((PaneGroupCommand) -> Bool)?
    /// Debounces height persistence during drags (state itself updates live).
    @ObservationIgnored private var pendingHeightSave: Task<Void, Never>?

    init(
        sessionId: UUID,
        placement: PaneGroupPlacement = .bottom,
        repository: any PaneGroupRepository,
        pluginIconClient: (any CodevisorServerClienting)? = nil,
        pluginIconCacheNamespace: String = "preview",
        makeContext: @escaping (PaneDescriptorState) -> PaneContext
    ) {
        self.sessionId = sessionId
        self.placement = placement
        self.repository = repository
        self.pluginIconClient = pluginIconClient
        self.pluginIconCacheNamespace = pluginIconCacheNamespace
        self.makeContext = makeContext
        if let stored = repository.load(sessionId: sessionId, placement: placement) {
            self.state = stored
        } else {
            // Persist immediately so both placements have repository state.
            // Bottom starts empty; its first terminal is created by toggle().
            let initial: PaneGroupState =
                switch placement {
                case .bottom: PaneGroupState()
                case .center: .centerInitial(sessionId: sessionId)
                }
            self.state = initial
            repository.save(initial, sessionId: sessionId, placement: placement)
        }
    }

    // MARK: - Live panes

    /// The live pane for a descriptor, built on first use. New pane kinds add
    /// a factory branch here.
    func pane(for descriptor: PaneDescriptorState) -> any Pane {
        if let existing = live[descriptor.id] { return existing }
        let pane: any Pane
        switch descriptor.kind {
        case .terminal:
            pane = TerminalPane(context: makeContext(descriptor))
        case .plugin:
            let plugin = PluginPane(context: makeContext(descriptor), descriptor: descriptor)
            // `codevisor.setTitle` renames the pane's tab like a manual
            // rename would (persisted + published).
            plugin.onTitleChange = { [weak self] title in
                self?.renamePane(id: descriptor.id, to: title)
            }
            pane = plugin
        // The New Tab placeholder rides the chat pane's plumbing: an
        // AnyView host resolving content from the live descriptor via
        // `chatContent` (the container branches on kind there).
        case .chat, .newTab:
            let chat = ChatPane(id: descriptor.id)
            wireChatHost(chat, paneId: descriptor.id)
            pane = chat
        }
        pane.onGroupCommand = { [weak self] command in self?.handleCommand(command) }
        pane.onFocusChanged = { [weak self] focused in
            self?.paneFocusChanged(id: descriptor.id, focused: focused)
        }
        live[descriptor.id] = pane
        return pane
    }

    /// Binds a ChatPane host to THIS group: content resolves from the LIVE
    /// descriptor on every render (a draft transmutes into its session's
    /// chat the moment first-send binds it). Called at creation AND on
    /// adoption — a pane moved from another group carries a provider bound
    /// to its OLD model, whose descriptor lookup fails (the pane left) and
    /// renders nothing.
    func wireChatHost(_ chat: ChatPane, paneId: UUID) {
        // Chat panes hand focus to their composer. A New Tab placeholder has
        // no editor, but still needs a neutral focus target so selecting it
        // releases a terminal or another panel's controls.
        chat.onFocus = { [weak self, paneId] in
            guard let self,
                let descriptor = self.state.panes.first(where: { $0.id == paneId })
            else { return }
            switch descriptor.kind {
            case .chat:
                self.requestComposerFocus?()
            case .newTab:
                self.requestBackgroundFocus?()
            case .terminal, .plugin:
                break
            }
        }
        chat.contentProvider = { [weak self, paneId] in
            guard let self,
                let current = self.state.panes.first(where: { $0.id == paneId }),
                let content = self.chatContent
            else { return AnyView(EmptyView()) }
            return content(current)
        }
    }

    /// The live chat pane, if this group hosts one (center groups do). Used
    /// by the session screen to provide the chat's content.
    var chatPane: ChatPane? {
        guard let descriptor = state.panes.first(where: { $0.kind == .chat }) else { return nil }
        return pane(for: descriptor) as? ChatPane
    }

    func paneFocusChanged(id: UUID, focused: Bool) {
        if focused {
            focusedPaneIds.insert(id)
            onActivated?()
        } else {
            focusedPaneIds.remove(id)
        }
        let hasFocus = !focusedPaneIds.isEmpty
        if hasFocusedPane != hasFocus {
            hasFocusedPane = hasFocus
        }
    }

    /// Keyboard shortcuts forwarded from a focused pane. Center leaves first
    /// offer them to the workspace container; bottom-panel groups retain
    /// local tab selection and terminal creation behavior.
    func handleCommand(_ command: PaneGroupCommand) {
        if placement == .center, workspaceCommandHandler?(command) == true { return }
        switch command {
        case .newTab:
            // ⌘T opens the "New tab" page (Chrome semantics — pick what the
            // tab becomes there); the bottom panel keeps spawning terminals
            // directly, since terminals are all it hosts.
            if placement == .bottom {
                addTerminalPane()
                DispatchQueue.main.async { [weak self] in self?.focusSelectedPane() }
            } else {
                addNewTabPane()
                DispatchQueue.main.async { [weak self] in self?.focusSelectedPane() }
            }
        case .nextTab, .previousTab:
            let panes = state.panes
            guard panes.count > 1,
                let index = panes.firstIndex(where: { $0.id == state.selectedPaneId })
            else { return }
            let step: Int = if case .nextTab = command { 1 } else { -1 }
            let target = panes[(index + step + panes.count) % panes.count]
            select(id: target.id)
            DispatchQueue.main.async { [weak self] in self?.focusSelectedPane() }
        case .selectTab(let index):
            guard state.panes.indices.contains(index) else { return }
            select(id: state.panes[index].id)
            DispatchQueue.main.async { [weak self] in self?.focusSelectedPane() }
        case .split, .focusSplit, .previousSplit, .nextSplit:
            return
        case .togglePanel:
            requestToggle?()
        case .closeTab:
            guard let selected = state.selectedPane,
                canClose(id: selected.id)
            else { return }
            let wasLastTab = state.panes.count == 1
            closePane(id: selected.id)
            if wasLastTab {
                // The group collapsed with the tab; hand focus back.
                requestComposerFocus?()
            } else {
                DispatchQueue.main.async { [weak self] in self?.focusSelectedPane() }
            }
        }
    }

    var selectedPane: (any Pane)? {
        state.selectedPane.map(pane(for:))
    }

    /// Applies pane content reconciled from the shared workspace registry to
    /// this mounted group without treating it as a local edit. In particular,
    /// this does not persist or call `onPaneChanged`/`onPaneRemoved`: the
    /// repository already contains the reconciled state and echoing it would
    /// turn an inbound server snapshot into another outbound mutation.
    ///
    /// New Tab and chat share the same live host, so their in-place promotion
    /// keeps focus and view identity. Renderer changes that need a different
    /// host discard only that pane's live object and rebuild lazily.
    @discardableResult
    func reconcileExternalState(_ incoming: PaneGroupState) -> Bool {
        let previousById = Dictionary(uniqueKeysWithValues: state.panes.map { ($0.id, $0) })
        var reconciled = state
        guard reconciled.reconcilePaneDescriptors(from: incoming) else { return false }
        let nextById = Dictionary(uniqueKeysWithValues: reconciled.panes.map { ($0.id, $0) })
        var invalidatedLiveIds = Set<UUID>()

        for id in Array(live.keys) {
            guard let previous = previousById[id], let next = nextById[id] else {
                discardLivePane(id: id)
                invalidatedLiveIds.insert(id)
                continue
            }
            if Self.requiresNewLivePane(previous: previous, next: next) {
                discardLivePane(id: id)
                invalidatedLiveIds.insert(id)
            }
        }

        let previousSelectedId = state.isVisible ? state.selectedPaneId : nil
        state = reconciled
        if let previousSelectedId,
            previousSelectedId != state.selectedPaneId,
            let previous = live[previousSelectedId]
        {
            previous.visibilityChanged(false)
        }
        if state.isVisible,
            previousSelectedId != state.selectedPaneId
                || state.selectedPaneId.map({ invalidatedLiveIds.contains($0) }) == true
        {
            selectedPane?.visibilityChanged(true)
        }
        return true
    }

    func focusSelectedPane() {
        // Focusing an already-selected tab is still user activity in this
        // group. This is load-bearing for a selected New Tab in an inactive
        // split: select(id:) is otherwise a no-op and never activates it.
        onActivated?()
        selectedPane?.focus()
    }

    func setHeight(_ height: CGFloat, isFinal: Bool = false) {
        state.setHeight(height)
        if isFinal {
            pendingHeightSave?.cancel()
            pendingHeightSave = nil
            persist()
        } else {
            // Debounce: one save shortly after the drag settles, not per tick.
            pendingHeightSave?.cancel()
            pendingHeightSave = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.persist()
            }
        }
    }

    /// App-side teardown for all live panes (backing shells survive on the
    /// server — app-quit semantics).
    func detachAll() {
        for pane in live.values {
            pane.detach()
        }
        live.removeAll()
    }

    func persist() {
        repository.save(state, sessionId: sessionId, placement: placement)
    }

    func discardLivePane(id: UUID) {
        guard let pane = live.removeValue(forKey: id) else { return }
        pane.visibilityChanged(false)
        pane.detach()
        paneFocusChanged(id: id, focused: false)
    }

    static func requiresNewLivePane(
        previous: PaneDescriptorState,
        next: PaneDescriptorState
    ) -> Bool {
        switch (previous.kind, next.kind) {
        case (.chat, .chat), (.chat, .newTab), (.newTab, .chat), (.newTab, .newTab):
            // ChatPane resolves the current descriptor on every render.
            return false
        case (.terminal, .terminal):
            // TerminalPane captures connection identity in its PaneContext.
            return previous.terminalKey != next.terminalKey
                || previous.attachOnly != next.attachOnly
        case (.plugin, .plugin):
            // PluginPane captures the plugin identity at creation; a pane
            // re-pointed at another plugin/pane type needs a fresh webview.
            return previous.pluginId != next.pluginId
                || previous.pluginPaneType != next.pluginPaneType
        default:
            return true
        }
    }
}
