import CoreGraphics
import Foundation
import QuartzCore

/// The motion of a send, measured frame by frame from iMessage recordings.
///
/// - The outgoing bubble leaves the composer on an underdamped spring: it
///   rises past its slot by 3–4% of its travel (about 10–15 pt on a phone)
///   and eases back with one visible rebound, settled in about 0.75 s.
/// - Everything already in the transcript makes room on a critically damped
///   spring that starts at once and never overshoots, so history leads and
///   the bubble follows it in.
public enum TranscriptSendMotion {
  public static let bubble = TranscriptSpring(response: 0.5, dampingFraction: 0.74)
  public static let content = TranscriptSpring(response: 0.31, dampingFraction: 1)

  /// The flying bubble, text and all, starts this much smaller than its
  /// slot and grows to full size on the bubble spring (with its slight
  /// overshoot). Close to 1 so the composer's glyphs, which share the
  /// transform, settle into the bubble rather than visibly shrinking.
  public static let bubbleStartScale: CGFloat = 0.96

  /// The composer's glyphs become the bubble's over this crossfade while
  /// both are already moving.
  public static let crossfadeDuration: TimeInterval = 0.12

  /// Rows that arrive below a flying bubble (the harness's first status
  /// line, a setup section) wait until the bubble is almost home, then fade.
  public static let followerRevealDelay: TimeInterval = 0.32
  public static let followerFadeDuration: TimeInterval = 0.2

  /// How long after a send the transcript keeps animating its own layout
  /// changes. Covers the flight and the usual server response, so a status
  /// row that appears after the bubble lands still slides in.
  public static let transitionWindow: TimeInterval = 2.5

  /// A composer snapshot the transcript never claims (the send failed its
  /// guards, the chat closed) fades out after this long.
  public static let stagingTimeout: TimeInterval = 2

  /// Row presentation that waits for its flight is hidden for at most this
  /// long; the flight replaces it with its own bounded hide.
  public static let targetHoldLimit: TimeInterval = 1.5
}

/// The Core Animation keys a transcript uses for send presentation.
public enum TranscriptSendAnimationKeys {
  /// The row lift used when no composer snapshot is flying.
  public static let lift = "codevisor.send-lift"
  /// Destination hidden while its composer snapshot flies to it.
  public static let hide = "codevisor.send-hide"
  /// Rows that arrive under the bubble fade in once it has landed.
  public static let follower = "codevisor.send-follower"
  /// Layout movement during a send; additive, so several compose.
  public static let shiftPrefix = "codevisor.send-shift."

  static let fixedKeys = [lift, hide, follower]
}

/// Factories for every send animation. Both platforms build identical
/// animations here, so timing, springs, and fill behavior cannot drift.
public enum TranscriptSendLayerAnimations {
  /// An additive spring from `offset` back to the layer's model value.
  /// Additive animations compose: when the model moves again mid-flight
  /// (a status row arrives, a height is corrected), a second animation
  /// adds its own offset without cancelling the first, so nothing jumps.
  public static func additiveSpring(
    keyPath: String,
    offset: Any,
    zero: Any,
    spring: TranscriptSpring,
    beginTime: CFTimeInterval = 0
  ) -> CASpringAnimation {
    let animation = CASpringAnimation(keyPath: keyPath)
    animation.mass = spring.mass
    animation.stiffness = spring.stiffness
    animation.damping = spring.damping
    animation.initialVelocity = 0
    animation.fromValue = offset
    animation.toValue = zero
    animation.isAdditive = true
    animation.duration = spring.settlingDuration()
    animation.beginTime = beginTime
    animation.fillMode = .backwards
    animation.isRemovedOnCompletion = true
    return animation
  }

  public static func translation(
    _ offset: CGSize,
    spring: TranscriptSpring,
    beginTime: CFTimeInterval = 0
  ) -> CASpringAnimation {
    additiveSpring(
      keyPath: "transform.translation",
      offset: NSValue.transcriptSize(offset),
      zero: NSValue.transcriptSize(.zero),
      spring: spring,
      beginTime: beginTime
    )
  }

  public static func verticalShift(
    _ offset: CGFloat,
    beginTime: CFTimeInterval = 0
  ) -> CASpringAnimation {
    additiveSpring(
      keyPath: "transform.translation.y",
      offset: offset,
      zero: CGFloat(0),
      spring: TranscriptSendMotion.content,
      beginTime: beginTime
    )
  }

  public static func fade(
    from: Float,
    to: Float,
    duration: CFTimeInterval,
    beginTime: CFTimeInterval = 0
  ) -> CABasicAnimation {
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = from
    fade.toValue = to
    fade.duration = duration
    fade.beginTime = beginTime
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    fade.fillMode = .both
    fade.isRemovedOnCompletion = true
    return fade
  }

  /// Hides a layer's presentation for at most `duration`. The model stays
  /// visible, so losing the animation can only ever reveal the row early.
  public static func hide(duration: CFTimeInterval) -> CABasicAnimation {
    let hold = CABasicAnimation(keyPath: "opacity")
    hold.fromValue = 0
    hold.toValue = 0
    hold.duration = duration
    hold.isRemovedOnCompletion = true
    return hold
  }

  /// Replays an in-progress content shift on a layer that joined late (a
  /// row mounted mid-transition), sharing the original clock so it moves in
  /// lockstep with rows that were already on screen.
  public static func replay(_ shift: TranscriptSendShift, on layer: CALayer) {
    layer.add(verticalShift(shift.offset, beginTime: shift.beginTime), forKey: shift.key)
  }

  /// Scrubs every send presentation animation and restores full opacity.
  public static func removeAll(from layer: CALayer) {
    for key in TranscriptSendAnimationKeys.fixedKeys {
      layer.removeAnimation(forKey: key)
    }
    for key in layer.animationKeys() ?? [] where key.hasPrefix(TranscriptSendAnimationKeys.shiftPrefix) {
      layer.removeAnimation(forKey: key)
    }
    layer.opacity = 1
  }
}

/// One layout movement applied to every visible row during a send.
public struct TranscriptSendShift: Equatable, Sendable {
  public let offset: CGFloat
  public let beginTime: CFTimeInterval
  public let key: String

  public init(offset: CGFloat, beginTime: CFTimeInterval, serial: UInt64) {
    self.offset = offset
    self.beginTime = beginTime
    key = TranscriptSendAnimationKeys.shiftPrefix + String(serial)
  }

  public func isRunning(at time: CFTimeInterval) -> Bool {
    time < beginTime + TranscriptSendMotion.content.settlingDuration()
  }
}

extension NSValue {
  static func transcriptSize(_ size: CGSize) -> NSValue {
    #if canImport(UIKit)
      NSValue(cgSize: size)
    #else
      NSValue(size: size)
    #endif
  }

  static func transcriptPoint(_ point: CGPoint) -> NSValue {
    #if canImport(UIKit)
      NSValue(cgPoint: point)
    #else
      NSValue(point: point)
    #endif
  }
}
