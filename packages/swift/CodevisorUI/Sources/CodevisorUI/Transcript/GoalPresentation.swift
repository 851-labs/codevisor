import ACPKit
import Foundation

/// Platform-neutral goal copy and compact metric formatting shared by the
/// keyboard-oriented macOS banner and touch-oriented iOS management flow.
public enum GoalPresentation {
    public static func statusText(for status: GoalStatus) -> String {
        switch status {
        case .active: "Active"
        case .paused: "Paused"
        case .blocked: "Blocked"
        case .usageLimited: "Usage limited"
        case .budgetLimited: "Budget limited"
        case .complete: "Complete"
        }
    }

    public static func activityText(for activity: GoalActivity) -> String {
        switch activity {
        case .planning: "Planning"
        case .verifying: "Verifying"
        }
    }

    public static func usageText(for goal: SessionGoal) -> String? {
        let parts = [
            goal.tokensUsed > 0 ? "\(tokens(goal.tokensUsed)) tokens" : nil,
            goal.timeUsedSeconds > 0 ? elapsed(goal.timeUsedSeconds) : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func tokens(_ count: Int) -> String {
        let formatted: String =
            switch count {
            case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
            case 1_000...: String(format: "%.1fk", Double(count) / 1_000)
            default: "\(count)"
            }
        return formatted.replacingOccurrences(of: ".0k", with: "k")
            .replacingOccurrences(of: ".0M", with: "M")
    }

    /// Compact elapsed format matching the CLI: "59s", "1h 30m", "1d 2h 3m".
    public static func elapsed(_ seconds: Double) -> String {
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
