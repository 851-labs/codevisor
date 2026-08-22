import CoreGraphics
import Foundation

/// The single motion contract for every optimistic user-message lift.
///
/// Both an ordinary send and New Chat's cross-presentation handoff animate a
/// row that is already rendered at its final size. Only its vertical position
/// and opacity change; the bubble itself never stretches between two frames.
public struct TranscriptSendAnimationPlan: Equatable, Sendable {
    public let translationY: CGFloat
    public let duration: TimeInterval
    public let fadeDuration: TimeInterval
    public let controlPoint1: CGPoint
    public let controlPoint2: CGPoint

    public init(
        translationY: CGFloat,
        duration: TimeInterval,
        fadeDuration: TimeInterval,
        controlPoint1: CGPoint,
        controlPoint2: CGPoint
    ) {
        self.translationY = translationY
        self.duration = duration
        self.fadeDuration = fadeDuration
        self.controlPoint1 = controlPoint1
        self.controlPoint2 = controlPoint2
    }
}

public enum TranscriptSendAnimationContract {
    public static let duration: TimeInterval = 0.46
    public static let fadeDuration: TimeInterval = 0.12
    /// Core Animation delegates are a completion signal, not a visibility
    /// guarantee. Presentation-only holds remove themselves at this deadline
    /// even if lifecycle interruption prevents the delegate from firing.
    public static let interruptionGraceDuration: TimeInterval = 0.25
    public static let presentationSafetyDuration = duration + interruptionGraceDuration
    public static let controlPoint1 = CGPoint(x: 0.22, y: 1)
    public static let controlPoint2 = CGPoint(x: 0.36, y: 1)

    /// Builds the lift from the composer's editor center to the real
    /// transcript row's top edge. Width and height are intentionally absent:
    /// the final rendered row is translated, never resized into place.
    public static func plan(
        sourceY: CGFloat,
        targetY: CGFloat,
        reduceMotion: Bool = false
    ) -> TranscriptSendAnimationPlan? {
        let translationY = sourceY - targetY
        guard !reduceMotion, translationY > 1 else { return nil }
        return TranscriptSendAnimationPlan(
            translationY: translationY,
            duration: duration,
            fadeDuration: fadeDuration,
            controlPoint1: controlPoint1,
            controlPoint2: controlPoint2
        )
    }
}

/// Token-scoped ownership for one native send presentation.
///
/// The native AppKit/UIKit adapters own layers and animations; this small,
/// deterministic value owns only lifecycle decisions. In particular, a stale
/// Core Animation callback cannot finish a newer presentation, while detach
/// and watchdog paths can cancel the current token idempotently.
public struct TranscriptSendPresentationLifecycle: Equatable, Sendable {
    public private(set) var activeToken: UInt64?
    public private(set) var deadline: TimeInterval?

    public init() {}

    @discardableResult
    public mutating func begin(token: UInt64, at time: TimeInterval) -> TimeInterval {
        activeToken = token
        let deadline = time + TranscriptSendAnimationContract.presentationSafetyDuration
        self.deadline = deadline
        return deadline
    }

    public func owns(token: UInt64) -> Bool {
        activeToken == token
    }

    public func isExpired(token: UInt64, at time: TimeInterval) -> Bool {
        activeToken == token && deadline.map { time >= $0 } == true
    }

    @discardableResult
    public mutating func complete(token: UInt64) -> Bool {
        guard activeToken == token else { return false }
        reset()
        return true
    }

    /// Returns the cancelled token, or nil when already idle.
    @discardableResult
    public mutating func cancel() -> UInt64? {
        let token = activeToken
        reset()
        return token
    }

    private mutating func reset() {
        activeToken = nil
        deadline = nil
    }
}
