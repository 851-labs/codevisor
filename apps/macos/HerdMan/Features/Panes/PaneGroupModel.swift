//  The live pane group for one chat session: owns the persisted PaneGroupState
//  (tabs/selection/visibility/height), lazily instantiates live Pane objects
//  from their descriptors, fires the pane lifecycle hooks, and persists every
//  state mutation.

import Foundation
import Observation
import HerdManCore

@MainActor
@Observable
final class PaneGroupModel: Identifiable {
    let sessionId: UUID
    private(set) var state: PaneGroupState

    @ObservationIgnored private var live: [UUID: any Pane] = [:]
    @ObservationIgnored private let repository: any PaneGroupRepository
    @ObservationIgnored private let makeContext: (PaneDescriptorState) -> PaneContext
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
        live[descriptor.id] = pane
        return pane
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

    /// Closes a tab: fires the pane's willDelete hook (kills its backing
    /// resources) and moves selection per the state rules.
    func closePane(id: UUID) {
        guard let descriptor = state.panes.first(where: { $0.id == id }) else { return }
        // Instantiate if needed: a never-shown pane may still own a server
        // shell from a previous app run that willDelete must clean up.
        let closing = pane(for: descriptor)
        live[id] = nil
        state.closePane(id: id)
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
