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
    private(set) var state: PaneGroupState
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
    @ObservationIgnored private var live: [UUID: any Pane] = [:]
    @ObservationIgnored private let repository: any PaneGroupRepository
    @ObservationIgnored private let makeContext: (PaneDescriptorState) -> PaneContext
    /// Set by the session screen: performs the panel toggle with proper focus
    /// handoff (the screen owns the composer/terminal focus controller).
    @ObservationIgnored var requestToggle: (() -> Void)?
    /// Set by the session screen: moves keyboard focus to the composer (used
    /// when closing the last tab collapses the group, and as the chat pane's
    /// focus target).
    @ObservationIgnored var requestComposerFocus: (() -> Void)?
    /// Fired after a tab closes (the descriptor already removed) — the app
    /// layer cleans up per-pane resources (draft controllers) and archives
    /// closed established chats' sessions.
    @ObservationIgnored var onPaneClosed: ((PaneDescriptorState) -> Void)?
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
    /// Debounces height persistence during drags (state itself updates live).
    @ObservationIgnored private var pendingHeightSave: Task<Void, Never>?

    init(
        sessionId: UUID,
        placement: PaneGroupPlacement = .bottom,
        repository: any PaneGroupRepository,
        makeContext: @escaping (PaneDescriptorState) -> PaneContext
    ) {
        self.sessionId = sessionId
        self.placement = placement
        self.repository = repository
        self.makeContext = makeContext
        if let stored = repository.load(sessionId: sessionId, placement: placement) {
            self.state = stored
        } else {
            // Persist immediately so pane 1's legacy terminal key is pinned
            // before any surface attaches.
            let initial: PaneGroupState = switch placement {
            case .bottom: .initial(sessionId: sessionId)
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
    private func wireChatHost(_ chat: ChatPane, paneId: UUID) {
        // CHAT panes hand focus to the composer; a New Tab placeholder's
        // page is click-driven — focusing it must not grab some other
        // chat's composer (which would trip focus-follow and snap the tab
        // selection right back off the placeholder).
        chat.onFocus = { [weak self, paneId] in
            guard let self,
                  let descriptor = self.state.panes.first(where: { $0.id == paneId }),
                  descriptor.kind == .chat else { return }
            self.requestComposerFocus?()
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

    private func paneFocusChanged(id: UUID, focused: Bool) {
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

    /// Keyboard shortcuts forwarded from a focused pane: ⌘⌥←/→ navigate
    /// tabs (wrapping), ⌘T adds a terminal. Focus follows the new selection
    /// so the keyboard stays in the pane group.
    func handleCommand(_ command: PaneGroupCommand) {
        switch command {
        case .newTab:
            // ⌘T opens the "New tab" page (Chrome semantics — pick what the
            // tab becomes there); the bottom panel keeps spawning terminals
            // directly, since terminals are all it hosts.
            if placement == .bottom {
                addTerminalPane()
                DispatchQueue.main.async { [weak self] in self?.focusSelectedPane() }
            } else {
                // No focus handoff: the placeholder page is click-driven
                // (focusing it would send keystrokes to the chat composer).
                addNewTabPane()
            }
        case .nextTab, .previousTab:
            let panes = state.panes
            guard panes.count > 1,
                  let index = panes.firstIndex(where: { $0.id == state.selectedPaneId }) else { return }
            let step: Int = if case .nextTab = command { 1 } else { -1 }
            let target = panes[(index + step + panes.count) % panes.count]
            select(id: target.id)
            DispatchQueue.main.async { [weak self] in self?.focusSelectedPane() }
        case .selectTab(let index):
            guard state.panes.indices.contains(index) else { return }
            select(id: state.panes[index].id)
            DispatchQueue.main.async { [weak self] in self?.focusSelectedPane() }
        case .togglePanel:
            requestToggle?()
        case .closeTab:
            guard let selected = state.selectedPane,
                  canClose(id: selected.id) else { return }
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

    func focusSelectedPane() {
        selectedPane?.focus()
    }

    // MARK: - Operations

    /// Adds a terminal tab, selects it, opens the group, and returns the live
    /// pane (so callers can focus it).
    @discardableResult
    func addTerminalPane() -> any Pane {
        let previouslySelected = selectedPane
        let descriptor = state.addTerminalPane(sessionId: sessionId)
        persist()
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
    }

    /// Reverts a chat pane to an unbound draft (its session was deleted by
    /// a failed first-send setup).
    func unbindChatPane(paneId: UUID) {
        state.unbindChatPane(paneId: paneId)
        persist()
    }

    /// Replaces a dead chat pane (session gone) with a New Tab placeholder.
    func resetChatPaneToPlaceholder(id: UUID) {
        guard state.resetChatPaneToPlaceholder(id: id) != nil else { return }
        live[id] = nil
        persist()
    }

    /// Adds the "New tab" placeholder — spawned by the container when this
    /// group's last real pane closes and the group is the workspace's last.
    @discardableResult
    func addNewTabPane() -> any Pane {
        let previouslySelected = selectedPane
        let descriptor = state.addNewTabPane()
        persist()
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
        cwd: String? = nil
    ) {
        guard let converted = state.convertNewTabPane(
            id: id, to: kind, sessionId: sessionId,
            chatSessionId: chatSessionId, name: name, cwd: cwd
        ) else { return }
        // The placeholder's live host dies with the descriptor.
        live[id] = nil
        persist()
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
            && !liveKeys.contains(pane.terminalKey) {
            // closePane also deletes the server-side terminal (a no-op when
            // the kill already removed it).
            closePane(id: pane.id)
        }
    }

    /// Whether a tab may close: the group-local state rules plus the
    /// container's workspace-wide policy (lone-placeholder dissolve). Chats
    /// close like any tab — closing archives the session; a workspace with
    /// no chats left just shows its New Tab placeholder.
    func canClose(id: UUID) -> Bool {
        guard state.canClosePane(id: id),
              let descriptor = state.panes.first(where: { $0.id == id }) else { return false }
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
              canClose(id: id) else { return }
        // Instantiate if needed: a never-shown pane may still own a server
        // shell from a previous app run that willDelete must clean up.
        let closing = pane(for: descriptor)
        live[id] = nil
        if state.panes.count == 1 {
            // Closing the last tab also collapses the group. Suppress the
            // removal/collapse animations: the tab's exit transition would
            // otherwise replay in the already-collapsed bar (flicker).
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                state.closePane(id: id)
            }
        } else {
            state.closePane(id: id)
        }
        persist()
        Task { await closing.willDelete() }
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
            persist()
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

    private func persist() {
        repository.save(state, sessionId: sessionId, placement: placement)
    }
}
