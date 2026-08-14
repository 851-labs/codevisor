import Foundation

/// Timing for coalescing bursts of automatic sidebar reorders into a single
/// reflow.
///
/// The first order change of a burst commits immediately (it keeps an
/// isolated change feeling instant), then identity order is frozen — via
/// `InteractionDeferredOrder` — until the sort has been quiet for
/// `quietDelay`. Sustained churn cannot keep the list stale forever:
/// `maxHold` bounds how long a single hold may last.
public enum ReorderSettle {
    /// How long the desired order must stay unchanged before a held reorder
    /// commits.
    public static let quietDelay: TimeInterval = 0.6

    /// Upper bound on one settle hold, so continuous churn still surfaces
    /// fresh order a couple of times per burst instead of never.
    public static let maxHold: TimeInterval = 2.5

    /// The wait before the next commit attempt for a hold that started at
    /// `holdStart`: the quiet delay, shortened as the hold approaches
    /// `maxHold`.
    public static func delay(holdStart: Date, now: Date = Date()) -> TimeInterval {
        min(quietDelay, max(0, maxHold - now.timeIntervalSince(holdStart)))
    }
}
