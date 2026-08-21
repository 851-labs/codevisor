import CodevisorCore
import SwiftUI

/// The Safari-style tab switcher: a two-column grid of pane previews with
/// close buttons. All grid state (drag, zoom, measured frames) stays with
/// WorkspaceScreen; this view receives values and closures.
struct WorkspaceTabGridView<ReorderGesture: Gesture>: View {
    let panes: [PaneDescriptorState]
    let paneStorageId: UUID?
    let gridDrag: WorkspaceTabGridDragState?
    let gridDragGestureIsActive: Bool
    let gridLiftFeedback: Int
    let pendingNewTabZoomPaneId: UUID?
    let showsGrid: Bool
    let pluginIconClient: any CodevisorServerClienting
    let pluginIconCacheNamespace: String
    let title: (PaneDescriptorState) -> String
    let onSelect: (PaneDescriptorState) -> Void
    let onClose: (PaneDescriptorState) -> Void
    let moveAction: (PaneDescriptorState, Int) -> (() -> Void)?
    let reorderGesture: (PaneDescriptorState) -> ReorderGesture
    let onPaneCardFrames: ([UUID: CGRect]) -> Void
    let onDragGestureEnded: () -> Void
    let onGridHidden: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(panes) { pane in
                        PaneCard(
                            pane: pane,
                            title: title(pane),
                            snapshot: paneStorageId.flatMap {
                                PaneSnapshotCache.shared.image(
                                    for: pane.id,
                                    in: $0
                                )
                            },
                            pluginIconClient: pluginIconClient,
                            pluginIconCacheNamespace: pluginIconCacheNamespace,
                            onSelect: { onSelect(pane) },
                            onClose: { onClose(pane) },
                            onMoveEarlier: moveAction(pane, -1),
                            onMoveLater: moveAction(pane, 1)
                        )
                        .id(pane.id)
                        // The grid-owned lifted preview is the only copy that
                        // follows the finger. This fully transparent cell
                        // remains in layout as the insertion gap and moves
                        // with the canonical pane order.
                        .opacity(gridDrag?.pane.id == pane.id ? 0 : 1)
                        // Reordering must coexist with the close Button.
                        // High-priority recognition starved that nested
                        // control before it could receive an ordinary tap.
                        .simultaneousGesture(
                            reorderGesture(pane)
                        )
                    }
                }
                .padding(16)
            }
            .onChange(of: pendingNewTabZoomPaneId) { _, paneId in
                guard let paneId else { return }
                // A large workspace may append the new card below the lazy
                // grid's viewport. Make its measured card the real zoom
                // source without adding a second, competing scroll motion.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(paneId, anchor: .bottom)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .onPreferenceChange(PaneCardFramePreferenceKey.self) { frames in
            onPaneCardFrames(frames)
        }
        .sensoryFeedback(.selection, trigger: gridLiftFeedback)
        .onChange(of: gridDragGestureIsActive) { wasActive, isActive in
            if wasActive, !isActive {
                onDragGestureEnded()
            }
        }
        .onChange(of: showsGrid) { _, isShowing in
            if !isShowing {
                onGridHidden()
            }
        }
        .overlay {
            GeometryReader { proxy in
                gridDragOverlay(in: proxy)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func gridDragOverlay(in proxy: GeometryProxy) -> some View {
        if let drag = gridDrag {
            let containerFrame = proxy.frame(in: .global)
            let origin = CGPoint(
                x: drag.fingerLocation.x - drag.grabOffset.width - containerFrame.minX,
                y: drag.fingerLocation.y - drag.grabOffset.height - containerFrame.minY
            )
            PanePreviewTile(
                pane: drag.pane,
                snapshot: drag.snapshot,
                title: drag.title,
                pluginIconClient: pluginIconClient,
                pluginIconCacheNamespace: pluginIconCacheNamespace,
                showsCloseButton: false,
                onClose: {}
            )
            .frame(width: drag.size.width, height: drag.size.height)
            .scaleEffect(1 + 0.045 * drag.liftProgress)
            .shadow(
                color: Color.black.opacity(0.22 * drag.liftProgress),
                radius: 12 * drag.liftProgress,
                x: 0,
                y: 6 * drag.liftProgress
            )
            .position(
                x: origin.x + drag.size.width / 2,
                y: origin.y + drag.size.height / 2
            )
            .accessibilityHidden(true)
        }
    }
}
