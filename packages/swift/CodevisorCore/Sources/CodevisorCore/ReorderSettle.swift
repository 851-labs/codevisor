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

    /// Quiet delay for the pre-emptive hold taken when the app returns to
    /// the foreground. Deliberately longer than the reactive `quietDelay`:
    /// the lock is taken BEFORE recovery starts, and the hub reconnect plus
    /// the first snapshot commonly need a second or two — a 0.6s quiet
    /// release would drop the freeze before the catch-up burst even begins.
    public static let foregroundQuietDelay: TimeInterval = 2.5

    /// Upper bound for the foreground hold: catch-up replays several
    /// machines' worth of changes over a few seconds, and the ordinary
    /// `maxHold` let the list reflow repeatedly mid-burst. Long enough to
    /// absorb a typical multi-machine catch-up, short enough that a
    /// genuinely slow sync still surfaces fresh order.
    public static let foregroundMaxHold: TimeInterval = 8

    /// The wait before the next commit attempt for a hold that started at
    /// `holdStart`: the quiet delay, shortened as the hold approaches
    /// `maxHold`.
    public static func delay(
        holdStart: Date,
        now: Date = Date(),
        quietDelay: TimeInterval = ReorderSettle.quietDelay,
        maxHold: TimeInterval = ReorderSettle.maxHold
    ) -> TimeInterval {
        min(quietDelay, max(0, maxHold - now.timeIntervalSince(holdStart)))
    }
}
