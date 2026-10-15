import CoreGraphics
import Foundation
import QuartzCore

public enum TranscriptSendMotion {
  public static let bubble = TranscriptSpring(response: 0.4, dampingFraction: 0.74)
  public static let content = TranscriptSpring(response: 0.25, dampingFraction: 1)

  public static let bubbleStartScale: CGFloat = 0.96

  public static let crossfadeDuration: TimeInterval = 0.1

  public static let followerRevealDelay: TimeInterval = 0.26
  public static let followerFadeDuration: TimeInterval = 0.2

  public static let transitionWindow: TimeInterval = 2.5

  public static let stagingTimeout: TimeInterval = 2

  public static let targetHoldLimit: TimeInterval = 1.5
}

public enum TranscriptSendAnimationKeys {
  public static let lift = "codevisor.send-lift"
  public static let hide = "codevisor.send-hide"
  public static let follower = "codevisor.send-follower"
  public static let shiftPrefix = "codevisor.send-shift."

  static let fixedKeys = [lift, hide, follower]
}

public enum TranscriptSendLayerAnimations {
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

  public static func followerReveal(sendStartedAt: CFTimeInterval, now: CFTimeInterval) -> CABasicAnimation? {
    let revealAt = sendStartedAt + TranscriptSendMotion.followerRevealDelay
    guard now < revealAt + TranscriptSendMotion.followerFadeDuration else { return nil }
    return fade(from: 0, to: 1, duration: TranscriptSendMotion.followerFadeDuration, beginTime: revealAt)
  }

  public static func hide(duration: CFTimeInterval) -> CABasicAnimation {
    let hold = CABasicAnimation(keyPath: "opacity")
    hold.fromValue = 0
    hold.toValue = 0
    hold.duration = duration
    hold.isRemovedOnCompletion = true
    return hold
  }

  public static func replay(_ shift: TranscriptSendShift, on layer: CALayer) {
    layer.add(verticalShift(shift.offset, beginTime: shift.beginTime), forKey: shift.key)
  }

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
}
