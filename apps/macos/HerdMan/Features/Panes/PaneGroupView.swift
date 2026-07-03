//  The session bottom pane group's chrome: the always-visible tab bar (which
//  doubles as the drag-to-resize handle, inheriting the old status bar's role)
//  and the selected pane's content.

import SwiftUI
import AppKit
import HerdManCore

/// The tab bar: pane tabs + "new terminal" button on the left, the bottom
/// panel toggle on the right. Always visible; when the group is collapsed it
/// sits at the bottom of the session screen and tab clicks re-expand it.
struct PaneGroupBar: View {
    @Environment(\.theme) private var theme
    var group: PaneGroupModel
    var onToggle: () -> Void
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(group.state.panes) { pane in
                        PaneTab(
                            name: pane.name,
                            isSelected: pane.id == group.state.selectedPaneId,
                            onSelect: {
                                group.select(id: pane.id)
                                group.focusSelectedPane()
                            },
                            onClose: { group.closePane(id: pane.id) }
                        )
                    }
                    addPaneButton
                }
            }

            Spacer(minLength: 0)

            Button {
                onToggle()
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(group.state.isVisible ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.white))
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle bottom panel (⌘J)")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(theme.windowBackground)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) {
            if group.state.isVisible { Divider() }
        }
        .contentShape(Rectangle())
        .gesture(resizeGesture)
        .onHover { hovering in
            guard group.state.isVisible else { return }
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var addPaneButton: some View {
        Button {
            group.addTerminalPane()
            // Defer until SwiftUI has mounted the new pane's view.
            DispatchQueue.main.async { group.focusSelectedPane() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New terminal")
    }

    /// The whole bar doubles as the panel's resize handle while it's open
    /// (drag up = taller), exactly like the status bar it replaces.
    private var resizeGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                guard group.state.isVisible else { return }
                let start = dragStartHeight ?? group.state.height
                dragStartHeight = start
                group.setHeight(start - value.translation.height)
            }
            .onEnded { _ in
                if dragStartHeight != nil {
                    group.setHeight(group.state.height, isFinal: true)
                }
                dragStartHeight = nil
            }
    }
}

/// One tab: pane name plus a close button that appears on hover/selection.
private struct PaneTab: View {
    @Environment(\.theme) private var theme
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close terminal")
            .opacity(isHovered || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? theme.accent.opacity(0.18) : (isHovered ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}

/// The selected pane's content, mounted only while the group is open. Panes
/// cache their expensive backing state (the terminal caches its NSView), so
/// switching tabs restores rather than rebuilds.
struct PaneGroupContent: View {
    var group: PaneGroupModel

    var body: some View {
        if let pane = group.selectedPane {
            pane.makeView()
                .id(pane.id)
        }
    }
}
