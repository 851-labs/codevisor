import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

// MARK: - Tab actions

extension WorkspaceScreen {
    func select(_ pane: PaneDescriptorState) {
        openPaneFromGrid(pane)
    }

    private func openPaneFromGrid(_ pane: PaneDescriptorState) {
        let bottomChrome =
            pane.kind == .chat
            ? PaneSnapshotCache.shared.activeBottomChrome
            : 0
        guard showsGrid,
            tabZoomSurface == nil,
            let paneStorageId,
            let cardFrame = paneCardFrames[pane.id],
            let storedSnapshot = PaneSnapshotCache.shared.transitionSnapshot(
                for: pane.id,
                in: paneStorageId,
                bottomChrome: bottomChrome
            )
        else {
            selectPaneWithoutZoom(pane)
            return
        }

        let paneSnapshot: PaneTransitionSnapshot
        let isUncached: Bool
        if storedSnapshot.image != nil {
            paneSnapshot = storedSnapshot
            isUncached = false
        } else if let fallback = Self.renderPaneCanvas(
            for: pane,
            size: storedSnapshot.contentFrame.size,
            sourceCardFrame: cardFrame,
            displayScale: displayScale
        ) {
            // This image exists only to carry an unvisited card through the
            // exact same zoom. The live pane replaces it at the late handoff;
            // it is never written as if it were a real pane capture.
            paneSnapshot = PaneTransitionSnapshot(
                image: fallback,
                contentFrame: storedSnapshot.contentFrame,
                transitionView: nil,
                backdropView: nil
            )
            isUncached = true
        } else {
            selectPaneWithoutZoom(pane)
            return
        }

        guard
            let surface = WorkspaceTabZoomSurface.make(
                direction: .gridToPane,
                paneSnapshot: paneSnapshot,
                cardFrame: cardFrame,
                reduceMotion: accessibilityReduceMotion,
                handoffDelayFactor: isUncached
                    ? WorkspaceTabZoomTransitionContract.uncachedHandoffDelayFactor
                    : WorkspaceTabZoomTransitionContract.handoffDelayFactor
            )
        else {
            selectPaneWithoutZoom(pane)
            return
        }

        surface.install()
        tabZoomSurface = surface
        selectPaneWithoutZoom(pane)
        Task { @MainActor in
            // Commit the canonical pane before revealing it beneath the
            // expanding card. No second workspace or presentation is made.
            await Task.yield()
            surface.animate {
                if tabZoomSurface === surface { tabZoomSurface = nil }
            }
        }
    }

    private func selectPaneWithoutZoom(_ pane: PaneDescriptorState) {
        var state = panes
        state.selectedPaneId = pane.id
        paneBinding.wrappedValue = state
        setShowsGridWithoutAnimation(false)
    }

    /// Any tab can close — chats included, as on macOS. A final-pane close is
    /// optimistic conversion of that same identity; the server atomically
    /// confirms the conversion so two clients cannot manufacture replacements.
    func close(_ pane: PaneDescriptorState) {
        let owningWorkspaceId = resolvedWorkspace?.id
        var state = panes
        let replacement: PaneDescriptorState?
        if state.panes.count == 1 {
            replacement = state.replacePaneWithNewTab(id: pane.id)
            guard replacement != nil else { return }
        } else {
            replacement = nil
            guard state.closePane(id: pane.id) != nil else { return }
        }
        withAnimation(WorkspaceTabGridMotion.removal) {
            paneBinding.wrappedValue = state
        }
        if let paneStorageId {
            PaneSnapshotCache.shared.remove(
                paneId: pane.id,
                from: paneStorageId
            )
        }
        if pane.kind == .plugin {
            // Closing the tab drops this client's webview and web-content
            // process. The machine-side plugin remains available to other
            // clients, panes, and tools until the Codevisor server stops.
            PluginPaneCache.shared.remove(paneId: pane.id)
        }
        if pane.kind == .chat, let sessionId = pane.chatSessionId,
            let closed = environment.projectList.sessions.first(where: {
                $0.serverId == resolvedServerId && $0.id == sessionId
            })
        {
            environment.archiveSession(closed)
        }
        if let workspaceId = owningWorkspaceId {
            environment.workspaceSync.deletePane(
                id: pane.id,
                workspaceId: workspaceId,
                optimisticReplacement: replacement,
                client: environment.machines.client(for: resolvedServerId)
            )
        }
    }

    /// The canonical pane array is also the persisted order. Updating it at
    /// each crossed card gives the drag live Safari-style displacement and
    /// makes the latest order crash-safe without a second transient model.
    func reorderPane(_ paneId: UUID, onto targetPaneId: UUID) {
        var state = panes
        let previousOrder = state.panes.map(\.id)
        state.movePane(id: paneId, onto: targetPaneId)
        guard state.panes.map(\.id) != previousOrder else { return }
        withAnimation(WorkspaceTabGridMotion.reorder) {
            paneBinding.wrappedValue = state
        }
    }

    /// VoiceOver exposes the same persistent reorder without requiring the
    /// spatial drag gesture.
    func moveAction(
        for pane: PaneDescriptorState,
        offset: Int
    ) -> (() -> Void)? {
        guard let index = panes.panes.firstIndex(where: { $0.id == pane.id }) else {
            return nil
        }
        let targetIndex = index + offset
        guard panes.panes.indices.contains(targetIndex) else { return nil }
        let targetId = panes.panes[targetIndex].id
        return { reorderPane(pane.id, onto: targetId) }
    }

    /// Add the placeholder to the real grid first, then expand that exact
    /// card into its page like Safari. This remains the same pane and the same
    /// WorkspaceScreen throughout; only temporary pixels bridge the two
    /// canonical layout states.
    func addTab() {
        if let sourcePane = activePane ?? panes.panes.first {
            chatController(for: sourcePane)?.rememberCurrentComposerConfiguration()
        }
        var state = panes
        let newPane = state.addNewTabPane()
        paneBinding.wrappedValue = state
        publishPane(newPane)

        guard showsGrid, !accessibilityReduceMotion else {
            setShowsGridWithoutAnimation(false)
            return
        }

        pendingNewTabZoomPaneId = newPane.id
        Task { @MainActor in
            // Preference delivery normally starts the transition on the next
            // layout pass. Never leave input disabled if a lazy-grid card
            // cannot be measured for an exceptional layout.
            try? await Task.sleep(for: .milliseconds(350))
            guard pendingNewTabZoomPaneId == newPane.id else { return }
            pendingNewTabZoomPaneId = nil
            setShowsGridWithoutAnimation(false)
        }
    }

    /// The grid's back button returns to the workspace's last-open tab.
    func reopenSelectedPane() {
        guard let activePane else { return }
        openPaneFromGrid(activePane)
    }

    /// Snapshot the pane for its card, then reveal the workspace-local grid.
    func showGrid(from pane: PaneDescriptorState) {
        guard let paneStorageId else {
            showsGrid = true
            return
        }
        let paneSnapshot = PaneSnapshotCache.shared.captureKeyWindow(
            for: pane.id,
            in: paneStorageId,
            bottomChrome: pane.kind == .chat ? PaneSnapshotCache.shared.activeBottomChrome : 0
        )
        if pane.kind == .plugin {
            // The window capture can't see web content reliably
            // (drawHierarchy renders WKWebView blank on some OS versions);
            // WKWebView's own snapshotter can. It answers async — the stored
            // image upgrades the grid card as soon as it lands.
            PluginPaneCache.shared.capturePreview(paneId: pane.id) { image in
                PaneSnapshotCache.shared.store(image, for: pane.id, in: paneStorageId)
            }
        }
        guard tabZoomSurface == nil,
            !accessibilityReduceMotion,
            let paneSnapshot,
            let surface = WorkspaceTabZoomSurface.make(
                direction: .paneToGrid,
                paneSnapshot: paneSnapshot,
                // The grid has not mounted yet. A non-empty provisional
                // card is replaced by its measured frame before animation.
                cardFrame: CGRect(
                    x: 16,
                    y: paneSnapshot.contentFrame.minY,
                    width: 1,
                    height: 1
                ),
                reduceMotion: false
            )
        else {
            showsGrid = true
            return
        }

        surface.install()
        tabZoomSurface = surface
        pendingGridZoomPaneId = pane.id
        setShowsGridWithoutAnimation(true)

        Task { @MainActor in
            await Task.yield()
            startPendingGridZoomIfPossible()
            try? await Task.sleep(for: .milliseconds(250))
            guard pendingGridZoomPaneId == pane.id,
                tabZoomSurface === surface
            else { return }
            // A card can be absent when a large lazy grid has it offscreen.
            // Never strand a frozen overlay waiting for impossible geometry.
            pendingGridZoomPaneId = nil
            surface.cancel()
            if tabZoomSurface === surface { tabZoomSurface = nil }
        }
    }

    func startPendingGridZoomIfPossible() {
        guard let paneId = pendingGridZoomPaneId,
            let frame = paneCardFrames[paneId],
            let surface = tabZoomSurface
        else { return }

        // The full-screen source snapshot was captured before the grid
        // existed. Retarget that SAME snapshot once the real destination card
        // has a frame; recapturing here would incorrectly photograph the grid.
        guard
            surface.retarget(
                cardFrame: frame,
                reduceMotion: accessibilityReduceMotion
            )
        else {
            pendingGridZoomPaneId = nil
            surface.cancel()
            tabZoomSurface = nil
            return
        }
        pendingGridZoomPaneId = nil
        surface.animate {
            if tabZoomSurface === surface { tabZoomSurface = nil }
        }
    }

    /// A brand-new pane has no historical screenshot yet. Render the actual
    /// NewTabPaneView at the pane's fixed canvas size, then feed those pixels
    /// into the same grid-to-pane surface used by every existing tab. The
    /// live grid supplies the backdrop and the live new pane is committed
    /// underneath it before the expansion begins.
    func startPendingNewTabZoomIfPossible() {
        guard let paneId = pendingNewTabZoomPaneId,
            tabZoomSurface == nil,
            showsGrid,
            let paneStorageId,
            let pane = panes.panes.first(where: {
                $0.id == paneId && $0.kind == .newTab
            }),
            let cardFrame = paneCardFrames[paneId],
            let geometry = PaneSnapshotCache.shared.transitionSnapshot(
                for: paneId,
                in: paneStorageId
            ),
            let paneImage = Self.renderPaneCanvas(
                for: pane,
                size: geometry.contentFrame.size,
                sourceCardFrame: cardFrame,
                displayScale: displayScale
            )
        else { return }

        PaneSnapshotCache.shared.store(
            paneImage,
            for: paneId,
            in: paneStorageId
        )
        let paneSnapshot = PaneTransitionSnapshot(
            image: paneImage,
            contentFrame: geometry.contentFrame,
            transitionView: nil,
            // `make` snapshots the still-live grid before canonical pane
            // selection changes, preserving the inserted card underneath.
            backdropView: nil
        )
        guard
            let surface = WorkspaceTabZoomSurface.make(
                direction: .gridToPane,
                paneSnapshot: paneSnapshot,
                cardFrame: cardFrame,
                reduceMotion: accessibilityReduceMotion
            )
        else {
            pendingNewTabZoomPaneId = nil
            setShowsGridWithoutAnimation(false)
            return
        }

        surface.install()
        tabZoomSurface = surface
        pendingNewTabZoomPaneId = nil
        selectPaneWithoutZoom(pane)
        Task { @MainActor in
            await Task.yield()
            surface.animate {
                if tabZoomSurface === surface { tabZoomSurface = nil }
            }
        }
    }

    private func setShowsGridWithoutAnimation(_ value: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showsGrid = value }
    }
}
