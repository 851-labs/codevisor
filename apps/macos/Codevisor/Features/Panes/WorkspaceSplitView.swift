//  Renders one workspace tab's split tree. Every leaf contains exactly one
//  pane beneath a compact identity/action header. Branches are
//  resizable splits with the same owned divider grips as the inspector; a
//  drag rewrites the subtree's fractions
//  and persists the whole tree on release.

import SwiftUI
import AppKit
import CodevisorCore

struct WorkspaceSplitView: View {
    let node: SplitNode
    /// The most recently active center leaf. This remains resolved while
    /// focus temporarily moves to the bottom panel or another window.
    let activeLeafId: UUID?
    let groupModel: (UUID) -> PaneGroupModel
    let paneTitle: (PaneDescriptorState) -> String
    let sessionStore: SessionStore?
    let onSplitLeaf: (UUID, SplitEdge) -> Void
    let onRenameLeaf: (UUID, String) -> Void
    let onCloseLeaf: (UUID) -> Void
    /// Called with the updated WHOLE tree after a divider drag ends.
    let onTreeChanged: (SplitNode) -> Void
    /// Called with the WHOLE tree on every frame of a divider drag (render
    /// only, nothing persisted).
    var onLiveTreeChanged: ((SplitNode) -> Void)? = nil

    var body: some View {
        SplitNodeView(
            node: node,
            activeLeafId: activeLeafId,
            dimsInactiveLeaves: node.allGroups.count > 1,
            groupModel: groupModel,
            paneTitle: paneTitle,
            sessionStore: sessionStore,
            onSplitLeaf: onSplitLeaf,
            onRenameLeaf: onRenameLeaf,
            onCloseLeaf: onCloseLeaf,
            replaceNode: onTreeChanged,
            replaceLiveNode: { onLiveTreeChanged?($0) }
        )
    }
}

private struct SplitNodeView: View {
    let node: SplitNode
    let activeLeafId: UUID?
    let dimsInactiveLeaves: Bool
    let groupModel: (UUID) -> PaneGroupModel
    let paneTitle: (PaneDescriptorState) -> String
    let sessionStore: SessionStore?
    let onSplitLeaf: (UUID, SplitEdge) -> Void
    let onRenameLeaf: (UUID, String) -> Void
    let onCloseLeaf: (UUID) -> Void
    /// Replaces THIS node in its parent (recursion rebuilds the tree upward).
    let replaceNode: (SplitNode) -> Void
    /// Render-only twin of `replaceNode`, streamed during divider drags.
    let replaceLiveNode: (SplitNode) -> Void

    var body: some View {
        switch node {
        case let .group(id, _):
            SplitLeafView(
                leafId: id,
                isInactive: dimsInactiveLeaves && activeLeafId != nil && id != activeLeafId,
                groupModel: groupModel,
                paneTitle: paneTitle,
                sessionStore: sessionStore,
                onSplit: { edge in onSplitLeaf(id, edge) },
                onRename: { name in onRenameLeaf(id, name) },
                onClose: { onCloseLeaf(id) }
            )
        case let .split(orientation, children):
            SplitBranchView(
                orientation: orientation,
                children: children,
                activeLeafId: activeLeafId,
                dimsInactiveLeaves: dimsInactiveLeaves,
                groupModel: groupModel,
                paneTitle: paneTitle,
                sessionStore: sessionStore,
                onSplitLeaf: onSplitLeaf,
                onRenameLeaf: onRenameLeaf,
                onCloseLeaf: onCloseLeaf,
                replaceNode: replaceNode,
                replaceLiveNode: replaceLiveNode
            )
        }
    }
}

/// One single-pane split leaf. The header is split chrome, not another tab
/// group: it identifies the pane and exposes leaf-targeted split actions.
private struct SplitLeafView: View {
    let leafId: UUID
    let isInactive: Bool
    let groupModel: (UUID) -> PaneGroupModel
    let paneTitle: (PaneDescriptorState) -> String
    let sessionStore: SessionStore?
    let onSplit: (SplitEdge) -> Void
    let onRename: (String) -> Void
    let onClose: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        let model = groupModel(leafId)
        VStack(spacing: 0) {
            SplitLeafHeader(
                pane: model.state.selectedPane,
                title: paneTitle,
                sessionStore: sessionStore,
                onActivate: { model.onActivated?() },
                onSplit: onSplit,
                onRename: onRename,
                onClose: onClose
            )
            ZStack {
                Color.clear
                PaneGroupContent(group: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { model.onActivated?() })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { inactiveSplitTint }
    }

    private var inactiveSplitTint: some View {
        Rectangle()
            .fill(theme.windowBackground)
            .opacity(isInactive ? 0.3 : 0)
            .allowsHitTesting(false)
            // Active-group changes should read as focus changes, not motion.
            .transaction { $0.animation = nil }
    }
}

private struct SplitLeafHeader: View {
    let pane: PaneDescriptorState?
    let title: (PaneDescriptorState) -> String
    let sessionStore: SessionStore?
    let onActivate: () -> Void
    let onSplit: (SplitEdge) -> Void
    let onRename: (String) -> Void
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @State private var renameText = ""
    @State private var showingRename = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onActivate) {
                HStack(spacing: 7) {
                    leadingIcon

                    Text(pane.map(title) ?? "New Tab")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(theme.textPrimary)

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            actionsMenu
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(theme.isSystem ? Color.clear : theme.windowBackground)
        .overlay(alignment: .bottom) { Divider() }
        .alert(renameAlertTitle, isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { onRename(renameText) }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var iconName: String {
        switch pane?.kind {
        case .chat: "text.bubble"
        case .terminal: pane?.attachOnly == true ? "server.rack" : "terminal"
        case .newTab, .none: "square.dashed"
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if pane?.kind == .chat,
           let sessionId = pane?.chatSessionId,
           let session = environment.projectList.sessions.first(where: { $0.id == sessionId }) {
            ChatSessionLeadingIcon(session: session, store: sessionStore)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 18)
        }
    }

    private var renameAlertTitle: String {
        switch pane?.kind {
        case .chat: "Rename Chat"
        case .terminal: "Rename Terminal"
        case .newTab, .none: "Rename Pane"
        }
    }

    private var closeTitle: String {
        pane?.kind == .chat && pane?.chatSessionId != nil ? "Archive" : "Close"
    }

    private var actionsMenu: some View {
        Menu {
            splitMenuItem("Split Right", icon: "rectangle.righthalf.inset.filled", edge: .trailing)
            splitMenuItem("Split Left", icon: "rectangle.lefthalf.inset.filled", edge: .leading)
            splitMenuItem("Split Down", icon: "rectangle.bottomhalf.inset.filled", edge: .bottom)
            splitMenuItem("Split Up", icon: "rectangle.tophalf.inset.filled", edge: .top)

            Divider()

            Button {
                renameText = pane.map(title) ?? "New Tab"
                showingRename = true
            } label: {
                    Label("Rename", systemImage: "pencil")
                    .labelStyle(.titleAndIcon)
            }

            Divider()

            Button(role: .destructive, action: onClose) {
                Label(closeTitle, systemImage: closeTitle == "Archive" ? "archivebox" : "xmark")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("w", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pane actions")
        .accessibilityLabel("Pane actions")
    }

    @ViewBuilder
    private func splitMenuItem(_ name: String, icon: String, edge: SplitEdge) -> some View {
        let button = Button { onSplit(edge) } label: {
            Label(name, systemImage: icon)
                .labelStyle(.titleAndIcon)
        }

        switch edge {
        case .trailing:
            button.keyboardShortcut("d", modifiers: .command)
        case .bottom:
            button.keyboardShortcut("d", modifiers: [.command, .shift])
        case .leading, .top:
            button
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
    let activeLeafId: UUID?
    let dimsInactiveLeaves: Bool
    let groupModel: (UUID) -> PaneGroupModel
    let paneTitle: (PaneDescriptorState) -> String
    let sessionStore: SessionStore?
    let onSplitLeaf: (UUID, SplitEdge) -> Void
    let onRenameLeaf: (UUID, String) -> Void
    let onCloseLeaf: (UUID) -> Void
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
                        activeLeafId: activeLeafId,
                        dimsInactiveLeaves: dimsInactiveLeaves,
                        groupModel: groupModel,
                        paneTitle: paneTitle,
                        sessionStore: sessionStore,
                        onSplitLeaf: onSplitLeaf,
                        onRenameLeaf: onRenameLeaf,
                        onCloseLeaf: onCloseLeaf,
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
