import SwiftUI

/// Centralized motion tokens for the transcript and session chrome, following
/// Apple's motion guidance (HIG › Motion; WWDC23 "Animate with springs"):
///
/// - Springs for all movement — interruptible and retargetable with no hard
///   stops, so a mid-flight re-tap or auto-collapse redirects smoothly instead
///   of jumping. Disclosure reveals use `.smooth` (zero bounce): their content
///   is clipped while height animates, so any overshoot would visibly clip.
/// - One shared timing per element class, instead of per-call-site durations.
/// - Reduce Motion honored — SwiftUI does NOT do this automatically for
///   `withAnimation`/`.animation`. Animation tokens return `nil` (commit
///   instantly) and transitions degrade to a plain crossfade.
///
/// Views read `@Environment(\.accessibilityReduceMotion)` and pass it in.
enum Motion {
    // MARK: - Animations

    /// Disclosure content reveal: the measured height + opacity unfold driven
    /// by `TranscriptDisclosureContentReveal`.
    static func reveal(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.25)
    }

    /// How long the reveal's phase machine waits before settling to natural
    /// height — past the spring's perceptual duration so the settle never
    /// lands mid-animation.
    static let revealSettleDelay: Duration = .milliseconds(300)

    /// Entrance of freshly revealed worked content (fade + slight drift).
    static func entrance(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.2)
    }

    /// Disclosure chevron rotation. Faster than the reveal it accompanies —
    /// the indicator should lead, not trail, the content.
    static func indicator(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.16)
    }

    /// Small transient chrome: todo panel, prompt queue, scroll-to-bottom
    /// button, diff counters. Smaller elements move a beat faster (HIG: scale
    /// duration to the size of the change), with snappy's slight liveliness.
    static func quick(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }

    /// Sidebar collection reflow after an item is removed. The archived row
    /// itself leaves immediately; surviving rows use a brief, zero-bounce
    /// settle so their new positions remain easy to track without making a
    /// frequent action feel delayed or playful.
    static func listReflow(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.2)
    }

    /// Panel-scale show/hide (e.g. the terminal pane group).
    static func panel(reduceMotion: Bool = false) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.25)
    }

    // MARK: - Transitions

    /// Content unfolding from under its header or edge: fade + a subtle
    /// anchored settle. Pure crossfade under Reduce Motion.
    static func unfold(reduceMotion: Bool = false, anchor: UnitPoint = .top) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.98, anchor: anchor))
    }

    /// Small floating chrome (e.g. the scroll-to-bottom button) pops in with
    /// fade + scale; pure crossfade under Reduce Motion.
    static func pop(reduceMotion: Bool = false) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.85))
    }
}
