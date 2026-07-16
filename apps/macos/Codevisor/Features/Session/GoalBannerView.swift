import ACPKit
import CodevisorCore
import SwiftUI

/// Session goal banner: objective, usage, and the pause/resume/clear controls.
/// Transient work belongs in the transcript alongside Thinking…, rather than
/// competing with the objective as a badge. Mounted above the composer whenever
/// the session has a goal; hidden entirely on harnesses without goal support.
/// Goals are created/replaced through the composer's goal-mode toggle.
struct GoalBannerView: View {
    @Bindable var controller: SessionController
    let goal: SessionGoal
    var glassNamespace: Namespace.ID? = nil

    @State private var isClearConfirmationPresented = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "target")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(goal.objective)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                usageLine
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .composerGlassSurface(
            cornerRadius: ComposerGlassStyle.accessoryCornerRadius,
            id: .goal,
            in: glassNamespace
        )
        .confirmationDialog(
            "Clear this goal?",
            isPresented: $isClearConfirmationPresented
        ) {
            Button("Clear Goal", role: .destructive) {
                Task { await controller.clearGoal() }
            }
        } message: {
            Text("The agent stops working toward “\(goal.objective)”.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Goal: \(goal.objective), \(statusText)")
    }

    @ViewBuilder
    private var usageLine: some View {
        let parts = [
            goal.tokensUsed > 0 ? "\(Self.tokens(goal.tokensUsed)) tokens" : nil,
            goal.timeUsedSeconds > 0 ? Self.elapsed(goal.timeUsedSeconds) : nil
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            if goal.status == .active {
                iconButton("pause.fill", help: "Pause goal") {
                    Task { await controller.pauseGoal() }
                }
            } else if goal.status != .complete {
                iconButton("play.fill", help: "Resume goal") {
                    Task { await controller.resumeGoal() }
                }
            }
            iconButton("pencil", help: "Edit goal — loads it into the composer") {
                controller.editGoal()
            }
            iconButton("xmark", help: "Clear goal") {
                isClearConfirmationPresented = true
            }
        }
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var statusText: String {
        switch goal.status {
        case .active: "Active"
        case .paused: "Paused"
        case .blocked: "Blocked"
        case .usageLimited: "Usage limited"
        case .budgetLimited: "Budget limited"
        case .complete: "Complete"
        }
    }

    static func tokens(_ count: Int) -> String {
        let formatted: String = switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(count) / 1_000)
        default: "\(count)"
        }
        // "54.0k" reads as noise — trim the empty fraction.
        return formatted.replacingOccurrences(of: ".0k", with: "k")
            .replacingOccurrences(of: ".0M", with: "M")
    }

    /// Compact elapsed format matching the codex TUI: "59s", "1h 30m", "1d 2h 3m".
    static func elapsed(_ seconds: Double) -> String {
        // Goal runtimes arrive with millisecond precision; the compact UI
        // intentionally displays completed whole seconds, matching Grok.
        let wholeSeconds = max(0, Int(seconds.rounded(.down)))
        if wholeSeconds < 60 { return "\(wholeSeconds)s" }
        let minutes = wholeSeconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        return "\(hours / 24)d \(hours % 24)h \(minutes % 60)m"
    }
}
