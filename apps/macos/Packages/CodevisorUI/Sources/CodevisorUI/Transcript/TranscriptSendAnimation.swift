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
