import SwiftUI
import AppKit
import HerdManCore

/// The bottom terminal panel for a session: just the terminal surface. Its
/// height is driven by `TerminalSession.panel`; the resize handle and toggle
/// live in the session's bottom status bar.
struct TerminalPanel: View {
    @Bindable var session: TerminalSession

    var body: some View {
        TerminalSurfaceView(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The status bar pinned to the bottom of the session page. Acts as the drag
/// handle for the bottom panel (terminal) and holds the bottom-panel toggle on
/// the far right.
struct SessionStatusBar: View {
    @Bindable var terminal: TerminalSession
    var onToggle: () -> Void

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button(action: onToggle) {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .font(.system(size: 13))
                    .foregroundStyle(terminal.panel.isVisible ? Color.accentColor : Color.white)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle bottom panel (⌘J)")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) {
            // When the panel is open, separate the status bar from the terminal.
            if terminal.panel.isVisible { Divider() }
        }
        .contentShape(Rectangle())
        .gesture(resizeGesture)
        .onHover { inside in
            if inside && terminal.panel.isVisible {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    /// Dragging the status bar resizes the bottom panel (drag up = taller).
    /// Only active while the panel is open.
    private var resizeGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                guard terminal.panel.isVisible else { return }
                let start = dragStartHeight ?? terminal.panel.height
                dragStartHeight = start
                terminal.panel.setHeight(start - value.translation.height)
            }
            .onEnded { _ in dragStartHeight = nil }
    }
}
