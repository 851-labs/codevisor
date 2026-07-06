//  The live pane group for one chat session: owns the persisted PaneGroupState
//  (tabs/selection/visibility/height), lazily instantiates live Pane objects
//  from their descriptors, fires the pane lifecycle hooks, and persists every
//  state mutation.

import Foundation
import Observation
import SwiftUI
import HerdManCore

@MainActor
@Observable
final class PaneGroupModel: Identifiable {
    let sessionId: UUID
    private(set) var state: PaneGroupState
    /// Terminal keys of agent background tasks that are currently RUNNING
    /// (per the latest snapshot). Read-only tabs hide their ✕ (there is no
    /// kill to offer) while their key is in here; once the process exits the
    /// ✕ returns so the tab can be dismissed. Not persisted — a restart with
    /// no live snapshot correctly treats every tab as settled.
    private(set) var runningAgentTerminalKeys: Set<String> = []

    @ObservationIgnored private var live: [UUID: any Pane] = [:]
    @ObservationIgnored private let repository: any PaneGroupRepository
    @ObservationIgnored private let makeContext: (PaneDescriptorState) -> PaneContext
    /// Set by the session screen: performs the panel toggle with proper focus
    /// handoff (the screen owns the composer/terminal focus controller).
    @ObservationIgnored var requestToggle: (() -> Void)?
    /// Set by the session screen: moves keyboard focus to the composer (used
    /// when closing the last tab collapses the group).
    @ObservationIgnored var requestComposerFocus: (() -> Void)?
    /// Debounces height persistence during drags (state itself updates live).
    @ObservationIgnored private var pendingHeightSave: Task<Void, Never>?

    init(
        sessionId: UUID,
        repository: any PaneGroupRepository,
        makeContext: @escaping (PaneDescriptorState) -> PaneContext
    ) {
        self.sessionId = sessionId
        self.repository = repository
        self.makeContext = makeContext
        if let stored = repository.load(sessionId: sessionId) {
            self.state = stored
        } else {
            // Persist immediately so pane 1's legacy terminal key is pinned
            // before any surface attaches.
            let initial = PaneGroupState.initial(sessionId: sessionId)
            self.state = initial
            repository.save(initial, sessionId: sessionId)
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
        }
        pane.onGroupCommand = { [weak self] command in self?.handleCommand(command) }
        live[descriptor.id] = pane
        return pane
    }

    /// Keyboard shortcuts forwarded from a focused pane: ⌘⌥←/→ navigate
    /// tabs (wrapping), ⌘T adds a terminal. Focus follows the new selection
    /// so the keyboard stays in the pane group.
    func handleCommand(_ command: PaneGroupCommand) {
        switch command {
        case .newTab:
            addTerminalPane()
            DispatchQueue.main.async { [weak self] in self?.focusSelectedPane() }
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
            guard let selected = state.selectedPaneId else { return }
            let wasLastTab = state.panes.count == 1
            closePane(id: selected)
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
        previouslySelected?.visibilityChanged(false)
        let added = pane(for: descriptor)
        added.visibilityChanged(true)
        return added
    }

    /// Syncs the agent's background-task snapshot into tabs: ensures a pane
    /// exists per task terminal (never stealing selection or opening the
    /// group — the tab appearing in the always-visible bar is the affordance)
    /// and tracks which keys are still running. Tabs are NOT removed when
    /// their task ends; the exit stays readable until the user closes them.
    func syncAgentTerminals(_ tasks: [(terminalKey: String, name: String, readOnly: Bool)]) {
        var added = false
        for task in tasks where !state.panes.contains(where: { $0.terminalKey == task.terminalKey }) {
            state.ensureAgentTerminalPane(
                name: task.name,
                terminalKey: task.terminalKey,
                readOnly: task.readOnly
            )
            added = true
        }
        if added {
            persist()
        }
        runningAgentTerminalKeys = Set(tasks.map(\.terminalKey))
    }

    /// Closes a tab: fires the pane's willDelete hook (kills its backing
    /// resources) and moves selection per the state rules.
    func closePane(id: UUID) {
        guard let descriptor = state.panes.first(where: { $0.id == id }) else { return }
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
        repository.save(state, sessionId: sessionId)
    }
}
