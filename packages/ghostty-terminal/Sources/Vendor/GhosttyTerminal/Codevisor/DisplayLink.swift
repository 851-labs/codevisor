// CODEVISOR-PATCH: file added. A CADisplayLink stand-in for the parts of
// MSDisplayLink (github.com/Lakr233/MSDisplayLink) that
// TerminalSurfaceCoordinator uses, so the vendored package has no further
// dependency.

#if canImport(UIKit)
import QuartzCore
import UIKit

struct DisplayLinkFrameRateRange {
    let minimum: Float
    let maximum: Float
    let preferred: Float
}

struct DisplayLinkCallbackContext {}

protocol DisplayLinkDelegate: AnyObject {
    func synchronization(context: DisplayLinkCallbackContext)
}

/// Calls its delegate once per display frame on the main run loop until it
/// is released.
@MainActor
final class DisplayLink {
    private let target = Target()
    /// Released on the main thread (TerminalSurfaceCoordinator is main-actor).
    nonisolated(unsafe) private let link: CADisplayLink

    init(preferredFrameRateRange range: DisplayLinkFrameRateRange) {
        link = CADisplayLink(target: target, selector: #selector(Target.tick))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: range.minimum, maximum: range.maximum, preferred: range.preferred)
        link.add(to: .main, forMode: .common)
    }

    func delegatingObject(_ delegate: DisplayLinkDelegate) {
        target.delegate = delegate
    }

    deinit {
        link.invalidate()
    }

    private final class Target: NSObject {
        weak var delegate: DisplayLinkDelegate?

        @objc func tick() {
            delegate?.synchronization(context: DisplayLinkCallbackContext())
        }
    }
}
#endif
