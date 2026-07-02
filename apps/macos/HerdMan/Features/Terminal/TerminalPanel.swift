import SwiftUI
import AppKit
import HerdManCore
import ACPKit

/// The bottom terminal panel for a session: just the terminal surface. Its
/// height is driven by `TerminalSession.panel`; the resize handle and toggle
/// live in the session's bottom status bar.
struct TerminalPanel: View {
    @Environment(\.theme) private var theme
    @Bindable var session: TerminalSession

    var body: some View {
        TerminalSurfaceView(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.terminalBackground)
    }
}

/// The status bar pinned to the bottom of the session page. Shows the session's
/// cost + token usage on the left, acts as the drag handle for the bottom panel
/// (terminal), and holds the bottom-panel toggle on the far right.
struct SessionStatusBar: View {
    @Environment(\.theme) private var theme
    var controller: SessionController
    @Bindable var terminal: TerminalSession
    var onToggle: () -> Void

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        HStack(spacing: 12) {
            usageView
            Spacer(minLength: 0)
            Button(action: onToggle) {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .font(.system(size: 13))
                    .foregroundStyle(terminal.panel.isVisible ? theme.accent : Color.white)
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

    /// Cost + token usage reported by the agent (`usage_update`), if any.
    @ViewBuilder
    private var usageView: some View {
        if let usage = controller.usage, usage.cost != nil || usage.used != nil {
            HStack(spacing: 12) {
                if let cost = usage.cost {
                    Text(Self.formatCost(cost))
                }
                if let used = usage.used {
                    Text(Self.formatTokens(used, size: usage.size))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    static func formatCost(_ cost: SessionCost) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = cost.currency
        formatter.maximumFractionDigits = cost.amount < 1 ? 4 : 2
        return formatter.string(from: NSNumber(value: cost.amount)) ?? String(format: "%.4f", cost.amount)
    }

    static func formatTokens(_ used: UInt64, size: UInt64?) -> String {
        if let size, size > 0 {
            return "\(abbreviate(used)) / \(abbreviate(size)) tokens"
        }
        return "\(abbreviate(used)) tokens"
    }

    private static func abbreviate(_ n: UInt64) -> String {
        let value = Double(n)
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return "\(n)"
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
