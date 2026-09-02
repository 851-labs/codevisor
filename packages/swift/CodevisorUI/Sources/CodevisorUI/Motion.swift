import SwiftUI

/// Centralized motion tokens for the transcript and session chrome, following
/// Apple's motion guidance (HIG › Motion; WWDC23 "Animate with springs"):
///
/// - Springs for all movement — interruptible and retargetable with no hard
///   stops, so a mid-flight re-tap or auto-collapse redirects smoothly instead
///   of jumping. Disclosure layout commits atomically; only its pixels animate.
/// - One shared timing per element class, instead of per-call-site durations.
/// - Reduce Motion honored — SwiftUI does NOT do this automatically for
///   `withAnimation`/`.animation`. Animation tokens return `nil` (commit
///   instantly) and transitions degrade to a plain crossfade.
///
/// Views read `@Environment(\.accessibilityReduceMotion)` and pass it in.
public enum Motion {
    /// Geometry duration for inserting a workspace split.
    public static let splitDuration = 0.22

    // MARK: - Animations

    /// Entrance of freshly revealed disclosure content (fade + slight drift).
    public static func entrance(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.2)
    }

    /// Disclosure chevron rotation. Faster than the reveal it accompanies —
    /// the indicator should lead, not trail, the content.
    public static func indicator(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.16)
    }

    /// Small transient chrome: todo panel, prompt queue, scroll-to-bottom
    /// button, diff counters. Smaller elements move a beat faster (HIG: scale
    /// duration to the size of the change), with snappy's slight liveliness.
    public static func quick(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }

    /// Sidebar collection reflow after an item is removed. The archived row
    /// itself leaves immediately; surviving rows use a brief, zero-bounce
    /// settle so their new positions remain easy to track without making a
    /// frequent action feel delayed or playful.
    public static func listReflow(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.2)
    }

    /// Panel-scale show/hide (e.g. the terminal pane group).
    public static func panel(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.25)
    }

    /// Workspace split geometry. A zero-bounce curve lets transcript text
    /// reflow continuously without the divider overshooting its destination.
    public static func split(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .smooth(duration: splitDuration)
    }

    // MARK: - Transitions

    /// Content unfolding from under its header or edge: fade + a subtle
    /// anchored settle. Pure crossfade under Reduce Motion.
    public static func unfold(reduceMotion: Bool = false, anchor: UnitPoint = .top) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.98, anchor: anchor))
    }

    /// Small floating chrome (e.g. the scroll-to-bottom button) pops in with
    /// fade + scale; pure crossfade under Reduce Motion.
    public static func pop(reduceMotion: Bool = false) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.85))
    }
}
