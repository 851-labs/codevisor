import CoreGraphics
import Foundation
import QuartzCore

/// The Core Animation keys a transcript surface uses for send presentation.
/// One vocabulary for both platforms and for the row hosts that must scrub
/// stale presentation state on reuse.
public enum TranscriptSendAnimationKeys {
  /// The outgoing user row's lift from the composer into its slot.
  public static let flight = "codevisor.user-send"
  /// Existing rows easing from their pre-send viewport position.
  public static let historyShift = "codevisor.send-history-shift"
  /// Existing rows held at their pre-send viewport position until the
  /// flight begins.
  public static let historyHold = "codevisor.send-history-hold"
  /// The destination row hidden until its flight begins.
  public static let targetHold = "codevisor.send-target-hold"
  /// A new assistant row hidden until the user row has landed.
  public static let assistantHold = "codevisor.send-assistant-hold"

  public static let all = [flight, historyShift, historyHold, targetHold, assistantHold]
}

/// Factories for the send presentation's layer animations. Both virtualizers
/// build identical animations; keeping the construction here means their
/// timing, easing, and fill behaviour cannot drift apart.
public enum TranscriptSendAnimationLayerAnimations {
  private static var timingFunction: CAMediaTimingFunction {
    CAMediaTimingFunction(
      controlPoints: Float(TranscriptSendAnimationContract.controlPoint1.x),
      Float(TranscriptSendAnimationContract.controlPoint1.y),
      Float(TranscriptSendAnimationContract.controlPoint2.x),
      Float(TranscriptSendAnimationContract.controlPoint2.y)
    )
  }

  /// The outgoing row's lift. Ordinary rows and New Chat's cross-sheet
  /// snapshot both use this, so position, fade, duration, and easing are
  /// shared by construction.
  public static func flight(plan: TranscriptSendAnimationPlan, fadesIn: Bool) -> CAAnimationGroup {
    let movement = CABasicAnimation(keyPath: "transform.translation.y")
    movement.fromValue = plan.translationY
    movement.toValue = 0
    movement.duration = plan.duration
    movement.timingFunction = CAMediaTimingFunction(
      controlPoints: Float(plan.controlPoint1.x),
      Float(plan.controlPoint1.y),
      Float(plan.controlPoint2.x),
      Float(plan.controlPoint2.y)
    )

    let animations: [CAAnimation]
    if fadesIn {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.toValue = 1
      fade.duration = plan.fadeDuration
      fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animations = [movement, fade]
    } else {
      animations = [movement]
    }

    let group = CAAnimationGroup()
    group.animations = animations
    group.duration = plan.duration
    group.fillMode = .backwards
    group.isRemovedOnCompletion = true
    return group
  }

  /// An existing row easing from its pre-send position to its final slot.
  public static func historyShift(translationY: CGFloat) -> CABasicAnimation {
    let movement = CABasicAnimation(keyPath: "transform.translation.y")
    movement.fromValue = translationY
    movement.toValue = 0
    movement.duration = TranscriptSendAnimationContract.duration
    movement.timingFunction = timingFunction
    movement.fillMode = .backwards
    movement.isRemovedOnCompletion = true
    return movement
  }

  /// A bounded presentation-only hold that keeps the model layer
  /// authoritative: it delays painting, and expiry or interruption reveals
  /// the model value automatically.
  public static func opacityHold() -> CABasicAnimation {
    let hold = CABasicAnimation(keyPath: "opacity")
    hold.fromValue = 0
    hold.toValue = 0
    hold.duration = TranscriptSendAnimationContract.presentationSafetyDuration
    hold.isRemovedOnCompletion = true
    return hold
  }

  /// A bounded hold at a pre-send vertical offset.
  public static func translationHold(_ translationY: CGFloat) -> CABasicAnimation {
    let hold = CABasicAnimation(keyPath: "transform.translation.y")
    hold.fromValue = translationY
    hold.toValue = translationY
    hold.duration = TranscriptSendAnimationContract.presentationSafetyDuration
    hold.isRemovedOnCompletion = true
    return hold
  }

  /// Scrubs every send presentation animation and restores full opacity.
  public static func removeAll(from layer: CALayer) {
    for key in TranscriptSendAnimationKeys.all {
      layer.removeAnimation(forKey: key)
    }
    layer.opacity = 1
    assert(layer.opacity == 1)
  }
}
