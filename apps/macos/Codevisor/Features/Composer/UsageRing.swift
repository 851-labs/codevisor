//  The composer's usage indicator: a small progress ring that fills as the
//  session's context window fills, with a hover popover showing cost + token
//  metrics. Successor of the removed status bar's usage text.

/* Usage gauge and popover are temporarily disabled.
import SwiftUI
import ACPKit
import CodevisorCore

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
    var limits: ServerHarnessUsageLimits?
    var isLoadingLimits = false
    var limitsError: String?
    var onRequestLimits: () async -> Void = {}

    @State private var isPopoverShown = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        if let usage, hasVisibleUsage(usage) {
            ring
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .onHover { hovering in
                    handleHover(hovering, requestLimits: true)
                }
                .popover(isPresented: $isPopoverShown, arrowEdge: .top) {
                    popoverContent(usage)
                }
                .accessibilityLabel(accessibilityText(usage))
                .accessibilityValue(contextAccessibilityValue(usage))
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
        VStack(alignment: .leading, spacing: 14) {
            sessionUsageSection(usage)
            accountLimitsSection
        }
        .padding(14)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .themedSurface(.popover)
        .onHover { hovering in
            handleHover(hovering, requestLimits: false)
        }
    }

    private func sessionUsageSection(_ usage: SessionUsage) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if let totalTokens = usage.totalTokens {
                    metricRow("Total tokens", UsageFormatting.abbreviate(totalTokens))
                }
                if let inputTokens = usage.inputTokens {
                    metricRow("Input", UsageFormatting.abbreviate(inputTokens))
                }
                if let cachedInputTokens = usage.cachedInputTokens {
                    metricRow("Cached input", UsageFormatting.abbreviate(cachedInputTokens))
                }
                if let outputTokens = usage.outputTokens {
                    metricRow("Output", UsageFormatting.abbreviate(outputTokens))
                }
                if let reasoningOutputTokens = usage.reasoningOutputTokens {
                    metricRow("Reasoning output", UsageFormatting.abbreviate(reasoningOutputTokens))
                }
                if let cost = usage.cost {
                    metricRow("Cost", UsageFormatting.formatCost(cost))
                }
            }
            .font(.caption)

            if let used = usage.used, let size = usage.size, size > 0 {
                let contextFraction = min(Double(used) / Double(size), 1)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Session usage")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(UsageFormatting.formatTokens(used, size: size))
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    ProgressView(value: contextFraction)
                        .tint(contextFraction > 0.85 ? theme.statusWarn : theme.accent)
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var accountLimitsSection: some View {
        if isLoadingLimits, limits == nil {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Loading harness limits…")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let limitsError, limits == nil {
            Text(limitsError)
                .font(.caption)
                .foregroundStyle(theme.statusError)
        } else if let limits, limits.state == "available" {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(limits.windows) { window in
                    usageLimitRow(window)
                }
                if let balance = limits.credits?.balance, shouldShowCreditsBalance(balance) {
                    Grid(alignment: .leading) {
                        metricRow("Credits", balance)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func handleHover(_ hovering: Bool, requestLimits: Bool) {
        hoverTask?.cancel()
        if hovering {
            isPopoverShown = true
            if requestLimits {
                Task { await onRequestLimits() }
            }
        } else {
            // Keep the popover alive while the pointer crosses the gap between
            // the ring and the separate popover window.
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                isPopoverShown = false
            }
        }
    }

    private func usageLimitRow(_ window: ServerHarnessUsageWindow) -> some View {
        let percent = min(max(window.usedPercent, 0), 100)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(percent.rounded()))% used")
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            .font(.caption)
            ProgressView(value: percent, total: 100)
                .tint(percent > 85 ? theme.statusWarn : theme.accent)
            if let reset = resetLabel(window.resetsAt) {
                Text(reset)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }

    private func hasVisibleUsage(_ usage: SessionUsage) -> Bool {
        usage.used != nil || usage.inputTokens != nil || usage.cachedInputTokens != nil ||
            usage.outputTokens != nil || usage.reasoningOutputTokens != nil ||
            usage.totalTokens != nil || usage.cost != nil
    }

    private func shouldShowCreditsBalance(_ balance: String) -> Bool {
        let numericCharacters = balance.filter {
            $0.isNumber || $0 == "." || $0 == "+" || $0 == "-"
        }
        guard numericCharacters.contains(where: \Character.isNumber) else { return true }
        return Double(numericCharacters).map { $0 != 0 } ?? true
    }

    private func resetLabel(_ value: String?) -> String? {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return nil }
        return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func accessibilityText(_ usage: SessionUsage) -> String {
        var parts: [String] = []
        if let total = usage.totalTokens {
            parts.append("\(UsageFormatting.abbreviate(total)) total session tokens")
        }
        if let cost = usage.cost { parts.append("Cost \(UsageFormatting.formatCost(cost))") }
        if let used = usage.used {
            parts.append(UsageFormatting.formatTokens(used, size: usage.size))
        }
        return parts.joined(separator: ", ")
    }

    private func contextAccessibilityValue(_ usage: SessionUsage) -> String {
        guard let used = usage.used, let size = usage.size, size > 0 else { return "" }
        return String(format: "%.0f percent context used", min(Double(used) / Double(size), 1) * 100)
    }
}
*/
