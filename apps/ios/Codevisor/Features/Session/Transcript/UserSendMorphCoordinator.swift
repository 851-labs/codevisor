import CodevisorUI
import SwiftUI
import UIKit

/// Where each user bubble currently sits on screen, by message id, so a
/// send can fly the composer's text into the exact bubble it becomes.
@MainActor
final class UserBubbleGeometryRegistry {
  static let shared = UserBubbleGeometryRegistry()
  private var frames: [UUID: CGRect] = [:]

  func record(_ messageID: UUID, frame: CGRect) {
    frames[messageID] = frame
  }

  func forget(_ messageID: UUID) {
    frames.removeValue(forKey: messageID)
  }

  func frame(for messageID: UUID) -> CGRect? {
    frames[messageID].flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// The composer's text becoming a bubble — iMessage's send, in one view.
///
/// `stage` runs on the Send tap: a proxy of the just-typed text is placed
/// exactly over the composer's text (the editor clears in the same frame,
/// so nothing visibly changes). When the transcript has laid out the real
/// bubble, `beginFlight` springs the proxy into that frame while the bubble
/// fills in behind it; the transcript reveals the real row on landing.
@MainActor
final class UserSendMorphCoordinator {
  static let shared = UserSendMorphCoordinator()

  private var proxy: UserSendMorphView?
  private var owner: ObjectIdentifier?
  /// The sheet expansion keeps the landed proxy on screen until its bitmap
  /// (which may predate the real row) is gone.
  private var holdsForExpansion = false
  private var flightEndedDuringHold = false
  private var stagingWatchdog: DispatchWorkItem?
  private var animators: [UIViewPropertyAnimator] = []

  var hasStagedProxy: Bool { proxy != nil && owner == nil }

  func stage(
    text: String,
    sourceFrame: CGRect,
    bubbleColor: UIColor,
    textColor: UIColor,
    in window: UIWindow?
  ) {
    removeProxy()
    IOSNavigationDiagnostics.record(
      "sendMorph.stage",
      "window=\(window != nil) chars=\(text.count) source=\(NSCoder.string(for: sourceFrame))"
    )
    guard let window, !text.isEmpty, !sourceFrame.isEmpty else { return }
    let view = UserSendMorphView(text: text, bubbleColor: bubbleColor, textColor: textColor)
    // The editor draws its text 4 pt below its top and flush left; the
    // bubble pads 8 pt / 12 pt. Start the proxy so its label lands on the
    // editor's glyphs.
    view.frame = sourceFrame.insetBy(dx: -UserSendMorphView.insets.left, dy: -4)
    // A bubble from the first frame: the editor's placeholder reappears
    // underneath the moment the text clears, and the pill must cover it.
    // The bubble tint is translucent, so composite it over the composer
    // card's surface here and over the transcript's surface on landing.
    view.backgroundColor = bubbleColor.composited(over: .secondarySystemGroupedBackground)
    view.layoutIfNeeded()
    window.addSubview(view)
    proxy = view
    owner = nil
    // A send that never produces a flight (failure, reduce motion) must
    // not leave a floating label behind.
    let watchdog = DispatchWorkItem { [weak self] in
      guard let self, owner == nil else { return }
      removeProxy()
    }
    stagingWatchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: watchdog)
  }

  /// Flies the staged proxy into `targetFrame` (window coordinates). Only
  /// the caller that began the flight may end it; other surfaces finishing
  /// their own presentations leave it alone.
  @discardableResult
  func beginFlight(
    owner newOwner: ObjectIdentifier,
    to targetFrame: CGRect,
    duration: TimeInterval
  ) -> Bool {
    IOSNavigationDiagnostics.record(
      "sendMorph.flight",
      "proxy=\(proxy != nil) owned=\(owner != nil) target=\(NSCoder.string(for: targetFrame)) durationMs=\(Int(duration * 1000)) "
        + "inWindow=\(proxy?.window != nil) animationsEnabled=\(UIView.areAnimationsEnabled) "
        + "from=\(proxy.map { NSCoder.string(for: $0.frame) } ?? "nil")"
    )
    guard let proxy, owner == nil, !targetFrame.isEmpty else { return false }
    owner = newOwner
    stagingWatchdog?.cancel()
    stagingWatchdog = nil
    proxy.superview?.bringSubviewToFront(proxy)
    let move = UIViewPropertyAnimator(
      duration: duration,
      timingParameters: UISpringTimingParameters(dampingRatio: 0.84, initialVelocity: .zero)
    )
    move.addAnimations {
      proxy.frame = targetFrame
      proxy.backgroundColor = proxy.bubbleColor.composited(over: .systemGroupedBackground)
      proxy.layoutIfNeeded()
    }
    animators = [move]
    let startedAt = CACurrentMediaTime()
    move.addCompletion { position in
      IOSNavigationDiagnostics.record(
        "sendMorph.flightDone",
        "position=\(position.rawValue) elapsedMs=\(Int((CACurrentMediaTime() - startedAt) * 1000))"
      )
    }
    move.startAnimation()
    return true
  }

  /// The sheet expansion draws above the window; a proxy still flying
  /// must stay on top of it.
  func bringFlightToFront() {
    guard let proxy else { return }
    proxy.superview?.bringSubviewToFront(proxy)
  }

  /// The sheet's content slides into the route's position during the
  /// expansion; a proxy still flying slides with it.
  func shiftFlight(by dy: CGFloat, duration: TimeInterval) {
    guard let proxy, owner != nil, dy != 0 else { return }
    let shift = UIViewPropertyAnimator(
      duration: duration,
      timingParameters: TranscriptSendAnimationMetrics.propertyTimingParameters
    )
    shift.addAnimations {
      proxy.transform = CGAffineTransform(translationX: 0, y: dy)
    }
    animators.append(shift)
    shift.startAnimation()
  }

  func endFlight(owner endingOwner: ObjectIdentifier) {
    IOSNavigationDiagnostics.record(
      "sendMorph.endFlight",
      "owned=\(owner == endingOwner) hold=\(holdsForExpansion)"
    )
    guard owner == endingOwner else { return }
    if holdsForExpansion {
      flightEndedDuringHold = true
      return
    }
    removeProxy()
  }

  func beginExpansionHold() {
    guard proxy != nil, owner != nil else { return }
    holdsForExpansion = true
    flightEndedDuringHold = false
  }

  func endExpansionHold() {
    guard holdsForExpansion else { return }
    holdsForExpansion = false
    if flightEndedDuringHold { removeProxy() }
  }

  private func removeProxy() {
    if proxy != nil {
      IOSNavigationDiagnostics.record(
        "sendMorph.removeProxy", "owned=\(owner != nil) animators=\(animators.count)")
    }
    holdsForExpansion = false
    flightEndedDuringHold = false
    stagingWatchdog?.cancel()
    stagingWatchdog = nil
    for animator in animators where animator.state == .active {
      animator.stopAnimation(true)
    }
    animators.removeAll()
    proxy?.removeFromSuperview()
    proxy = nil
    owner = nil
  }
}

/// A user bubble's look, as a plain UIView so it can be animated freely in
/// the window: the transcript's bubble is 12/8 padding, 14 pt corners, body
/// text.
final class UserSendMorphView: UIView {
  static let insets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
  let bubbleColor: UIColor
  private let label = UILabel()

  init(text: String, bubbleColor: UIColor, textColor: UIColor) {
    self.bubbleColor = bubbleColor
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    layer.cornerRadius = 14
    layer.cornerCurve = .continuous
    label.text = text
    label.font = .preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = textColor
    label.numberOfLines = 0
    addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = bounds.inset(by: Self.insets)
  }
}

extension UIColor {
  /// This color drawn over `base`, resolved per appearance — what a
  /// translucent bubble tint actually looks like on a given surface.
  func composited(over base: UIColor) -> UIColor {
    UIColor { traits in
      var (r1, g1, b1, a1) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
      var (r2, g2, b2, a2) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
      self.resolvedColor(with: traits).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
      base.resolvedColor(with: traits).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
      let alpha = a1 + a2 * (1 - a1)
      guard alpha > 0 else { return .clear }
      func blend(_ top: CGFloat, _ bottom: CGFloat) -> CGFloat {
        (top * a1 + bottom * a2 * (1 - a1)) / alpha
      }
      return UIColor(red: blend(r1, r2), green: blend(g1, g2), blue: blend(b1, b2), alpha: alpha)
    }
  }
}

extension UIWindow {
  /// The foreground scene's key window: where send proxies float.
  static var codevisorKeyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }?
      .windows.first(where: \.isKeyWindow)
  }
}
