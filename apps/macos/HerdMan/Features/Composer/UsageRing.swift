//  The composer's usage indicator: a small progress ring that fills as the
//  session's context window fills, with a hover popover showing cost + token
//  metrics. Successor of the removed status bar's usage text.

import SwiftUI
import ACPKit

/// Formatting for cost/usage figures (moved from the removed SessionStatusBar).
enum UsageFormatting {
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

    static func abbreviate(_ n: UInt64) -> String {
        let value = Double(n)
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return "\(n)"
    }
}

/// A ring that fills with context-window usage. Hidden until the agent reports
/// usage (`usage_update`). Hovering reveals a popover with the details.
struct UsageRingButton: View {
    @Environment(\.theme) private var theme
    var usage: SessionUsage?

    @State private var isPopoverShown = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        if let usage, usage.used != nil || usage.cost != nil {
            ring
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .onHover { hovering in
                    hoverTask?.cancel()
                    if hovering {
                        isPopoverShown = true
                    } else {
                        // Small delay so a pointer excursion toward the popover
                        // doesn't instantly dismiss it.
                        hoverTask = Task {
                            try? await Task.sleep(for: .milliseconds(120))
                            guard !Task.isCancelled else { return }
                            isPopoverShown = false
                        }
                    }
                }
                .popover(isPresented: $isPopoverShown, arrowEdge: .top) {
                    popoverContent(usage)
                }
                .accessibilityLabel(accessibilityText(usage))
        }
    }

    private var fraction: Double {
        guard let used = usage?.used, let size = usage?.size, size > 0 else { return 0 }
        return min(Double(used) / Double(size), 1)
    }

    private var ringColor: Color {
        fraction > 0.85 ? theme.statusWarn : theme.accent
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy(duration: 0.3), value: fraction)
        }
        .frame(width: 18, height: 18)
    }

    private func popoverContent(_ usage: SessionUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cost = usage.cost {
                metricRow(label: "Cost", value: UsageFormatting.formatCost(cost))
            }
            if let used = usage.used {
                metricRow(label: "Tokens", value: UsageFormatting.formatTokens(used, size: usage.size))
                if let size = usage.size, size > 0 {
                    metricRow(
                        label: "Context",
                        value: String(format: "%.0f%% used", min(Double(used) / Double(size), 1) * 100)
                    )
                }
            }
        }
        .font(.caption)
        .padding(10)
        .background(theme.popoverBackground)
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
        }
    }

    private func accessibilityText(_ usage: SessionUsage) -> String {
        var parts: [String] = []
        if let cost = usage.cost { parts.append("Cost \(UsageFormatting.formatCost(cost))") }
        if let used = usage.used { parts.append(UsageFormatting.formatTokens(used, size: usage.size)) }
        return parts.joined(separator: ", ")
    }
}
