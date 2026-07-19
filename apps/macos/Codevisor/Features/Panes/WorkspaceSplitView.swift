//  Renders a workspace's center split tree (the VS Code editor-grid model).
//  Leaves are tabbed pane groups, each rendering its OWN compact tab bar
//  over its content — a content band below the native toolbar, like
//  Finder's tab bar. Branches are resizable splits with the same owned
//  divider grips as the inspector; a drag rewrites the subtree's fractions
//  and persists the whole tree on release.

import SwiftUI
import AppKit
import CodevisorCore

struct WorkspaceSplitView: View {
    let node: SplitNode
    let groupModel: (UUID) -> PaneGroupModel
    let chatTitle: (PaneDescriptorState) -> String
    let paneWorktree: (PaneDescriptorState) -> String?
    /// Content drop zones (join/split) register here.
    var dragCoordinator: PaneTabDragCoordinator? = nil
    /// Whether a leaf's bar shows the ⌘-shortcut hints (the primary group
    /// while nothing else holds focus).
    var showsShortcutHints: (UUID) -> Bool = { _ in false }
    /// Called with the updated WHOLE tree after a divider drag ends.
    let onTreeChanged: (SplitNode) -> Void
    /// Called with the WHOLE tree on every frame of a divider drag (render
    /// only, nothing persisted).
    var onLiveTreeChanged: ((SplitNode) -> Void)? = nil

    var body: some View {
        SplitNodeView(
            node: node,
            groupModel: groupModel,
            chatTitle: chatTitle,
            paneWorktree: paneWorktree,
            dragCoordinator: dragCoordinator,
            showsShortcutHints: showsShortcutHints,
            replaceNode: onTreeChanged,
            replaceLiveNode: { onLiveTreeChanged?($0) }
        )
    }
}

private struct SplitNodeView: View {
    let node: SplitNode
    let groupModel: (UUID) -> PaneGroupModel
    let chatTitle: (PaneDescriptorState) -> String
    let paneWorktree: (PaneDescriptorState) -> String?
    let dragCoordinator: PaneTabDragCoordinator?
    let showsShortcutHints: (UUID) -> Bool
    /// Replaces THIS node in its parent (recursion rebuilds the tree upward).
    let replaceNode: (SplitNode) -> Void
    /// Render-only twin of `replaceNode`, streamed during divider drags.
    let replaceLiveNode: (SplitNode) -> Void

    var body: some View {
        switch node {
        case let .group(id, _):
            SplitLeafView(
                leafId: id,
                groupModel: groupModel,
                chatTitle: chatTitle,
                paneWorktree: paneWorktree,
                dragCoordinator: dragCoordinator,
                showsShortcutHints: showsShortcutHints
            )
        case let .split(orientation, children):
            SplitBranchView(
                orientation: orientation,
                children: children,
                groupModel: groupModel,
                chatTitle: chatTitle,
                paneWorktree: paneWorktree,
                dragCoordinator: dragCoordinator,
                showsShortcutHints: showsShortcutHints,
                replaceNode: replaceNode,
                replaceLiveNode: replaceLiveNode
            )
        }
    }
}

/// One tabbed group: its compact bar over its selected pane's content.
private struct SplitLeafView: View {
    let leafId: UUID
    let groupModel: (UUID) -> PaneGroupModel
    let chatTitle: (PaneDescriptorState) -> String
    let paneWorktree: (PaneDescriptorState) -> String?
    let dragCoordinator: PaneTabDragCoordinator?
    let showsShortcutHints: (UUID) -> Bool

    var body: some View {
        let model = groupModel(leafId)
        VStack(spacing: 0) {
            PaneGroupBar(
                group: model,
                dragCoordinator: dragCoordinator,
                chatTitle: chatTitle,
                paneWorktree: paneWorktree,
                showsShortcutHints: showsShortcutHints(leafId),
                allowsNewChatTab: true,
                chrome: .groupHeader
            )
            // The Color.clear backstop is load-bearing: if the selected
            // pane's content resolves to nothing (EmptyView is layout-
            // ABSENT, not just blank), the VStack would collapse to the
            // bar and center it in the split region — and the drop zone's
            // geometry would unregister with it.
            ZStack {
                Color.clear
                PaneGroupContent(group: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Join (⇧) / split drops land on this content.
            .paneDropZone(dragCoordinator, leafId: leafId)
        }
    }
}

/// The divider grip as a REAL AppKit view that owns its strip outright:
/// hit-testing, the resize cursor, and the drag. The cursor is re-asserted
/// on every tracked mouse move — the only thing that reliably beats a
/// terminal view continuously re-asserting its I-beam next door (SwiftUI
/// onHover push/pop and descendant cursor rects both lose that race under
/// NSHostingView).
private struct SplitDividerGrip: NSViewRepresentable {
    /// Branch orientation: horizontal branch → vertical divider →
    /// left/right resize; vertical branch → up/down.
    let isHorizontal: Bool
    /// Live translation along the branch axis since the drag started
    /// (SwiftUI sign convention: right/down positive).
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    final class GripView: NSView {
        var isHorizontal = true
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: (() -> Void)?
        private var dragStart: NSPoint?

        private var cursor: NSCursor {
            isHorizontal ? .resizeLeftRight : .resizeUpDown
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
        }

        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseMoved(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        override func mouseDown(with event: NSEvent) {
            // Screen coordinates: stable while our own layout moves under
            // the drag.
            dragStart = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            cursor.set()
            let now = NSEvent.mouseLocation
            // Screen space is y-up; SwiftUI's translation is y-down.
            let delta = isHorizontal ? now.x - dragStart.x : dragStart.y - now.y
            onChanged?(delta)
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
            onEnded?()
        }
    }

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.isHorizontal = isHorizontal
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: GripView, context: Context) {
        nsView.isHorizontal = isHorizontal
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }
}

/// A resizable H/V split: children sized by their fractions, separated by
/// hairline dividers whose grips drag-resize the two adjacent children.
private struct SplitBranchView: View {
    let orientation: SplitOrientation
    let children: [SplitChild]
    let groupModel: (UUID) -> PaneGroupModel
    let chatTitle: (PaneDescriptorState) -> String
    let paneWorktree: (PaneDescriptorState) -> String?
    let dragCoordinator: PaneTabDragCoordinator?
    let showsShortcutHints: (UUID) -> Bool
    let replaceNode: (SplitNode) -> Void
    let replaceLiveNode: (SplitNode) -> Void

    @Environment(\.theme) private var theme
    /// Fractions mid-drag (nil when idle); layout renders these live and the
    /// tree persists once on release.
    @State private var liveFractions: [Double]?
    @State private var dragStartFractions: [Double]?

    /// The smallest a child may shrink along this branch's axis, in points.
    /// Shared with the drop coordinator (which hides split previews whose
    /// halves would fall below it).
    private var minChildLength: CGFloat {
        orientation == .horizontal
            ? PaneTabDragCoordinator.minChildWidth
            : PaneTabDragCoordinator.minChildHeight
    }

    private var fractions: [Double] { liveFractions ?? children.map(\.fraction) }

    var body: some View {
        GeometryReader { geometry in
            let isHorizontal = orientation == .horizontal
            let axisLength = isHorizontal ? geometry.size.width : geometry.size.height
            let contentLength = max(axisLength - CGFloat(children.count - 1), 0)
            // Floor every child at the minimum usable length: divider drags
            // clamp already, but WINDOW resizes rescale all children at
            // once and could crush one below usability.
            let current = SplitNode.flooredFractions(
                fractions,
                minFraction: contentLength > 0
                    ? Double(minChildLength / contentLength) : 0
            )

            layout(isHorizontal: isHorizontal) {
                ForEach(children.indices, id: \.self) { index in
                    let length = contentLength * CGFloat(current[index])
                    SplitNodeView(
                        node: children[index].node,
                        groupModel: groupModel,
                        chatTitle: chatTitle,
                        paneWorktree: paneWorktree,
                        dragCoordinator: dragCoordinator,
                        showsShortcutHints: showsShortcutHints,
                        replaceNode: { newChild in
                            var updated = children
                            updated[index] = SplitChild(
                                fraction: updated[index].fraction,
                                node: newChild
                            )
                            replaceNode(.split(orientation: orientation, children: updated))
                        },
                        replaceLiveNode: { newChild in
                            var updated = children
                            updated[index] = SplitChild(
                                fraction: updated[index].fraction,
                                node: newChild
                            )
                            replaceLiveNode(.split(orientation: orientation, children: updated))
                        }
                    )
                    .frame(
                        width: isHorizontal ? length : nil,
                        height: isHorizontal ? nil : length
                    )
                    // Content must never bleed across the divider into a
                    // neighbor (the chat's composer overlay can outgrow a
                    // squeezed region during drags).
                    .clipped()

                    if index < children.count - 1 {
                        // Visual hairline only — the GRIP lives in the
                        // branch-level overlay below, where its 13pt strip
                        // is REAL layout. As a subview overhanging this 1pt
                        // separator it would show the resize cursor
                        // (tracking rects are window-level) while clicks in
                        // the overhang hit-tested into the neighboring pane.
                        theme.separator
                            .frame(
                                width: isHorizontal ? 1 : nil,
                                height: isHorizontal ? nil : 1
                            )
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                ForEach(0..<max(children.count - 1, 0), id: \.self) { index in
                    let cumulative = current[0...index].reduce(0, +)
                    let gripCenter = contentLength * CGFloat(cumulative) + CGFloat(index) + 0.5
                    grip(
                        afterIndex: index,
                        isHorizontal: isHorizontal,
                        contentLength: contentLength
                    )
                    .frame(
                        width: isHorizontal ? 13 : geometry.size.width,
                        height: isHorizontal ? geometry.size.height : 13
                    )
                    .offset(
                        x: isHorizontal ? gripCenter - 6.5 : 0,
                        y: isHorizontal ? 0 : gripCenter - 6.5
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func layout(
        isHorizontal: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if isHorizontal {
            HStack(spacing: 0, content: content)
        } else {
            VStack(spacing: 0, content: content)
        }
    }

    /// The invisible 13pt grip straddling a divider, hosted at branch level
    /// (its strip is real layout there, so hit-testing matches the cursor's
    /// tracking rect: wherever the resize cursor shows, the grab works).
    private func grip(
        afterIndex index: Int,
        isHorizontal: Bool,
        contentLength: CGFloat
    ) -> some View {
        SplitDividerGrip(
            isHorizontal: isHorizontal,
            onChanged: { translation in
                let start = dragStartFractions ?? children.map(\.fraction)
                dragStartFractions = start
                guard contentLength > 0 else { return }
                let minFraction = Double(minChildLength / contentLength)
                var delta = Double(translation / contentLength)
                // Clamp so neither neighbor collapses below the minimum.
                delta = max(delta, minFraction - start[index])
                delta = min(delta, start[index + 1] - minFraction)
                var updated = start
                updated[index] = start[index] + delta
                updated[index + 1] = start[index + 1] - delta
                liveFractions = updated
                replaceLiveNode(.split(
                    orientation: orientation,
                    children: zip(children, updated).map {
                        SplitChild(fraction: $1, node: $0.node)
                    }
                ))
            },
            onEnded: {
                if let liveFractions {
                    let updated = zip(children, liveFractions).map {
                        SplitChild(fraction: $1, node: $0.node)
                    }
                    replaceNode(.split(orientation: orientation, children: updated))
                }
                liveFractions = nil
                dragStartFractions = nil
            }
        )
    }
}
