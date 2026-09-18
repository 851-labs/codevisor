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

/// The native transcript phase that can temporarily suppress a newly-created
/// assistant row while a user message is handed off from the composer.
public enum TranscriptSendPresentationPhase: Equatable, Sendable {
  case idle
  case pending
  case active
}

public enum TranscriptSendAnimationContract {
  public static let duration: TimeInterval = 0.46
  public static let fadeDuration: TimeInterval = 0.12
  /// Core Animation delegates are a completion signal, not a visibility
  /// guarantee. Presentation-only holds remove themselves at this deadline
  /// even if lifecycle interruption prevents the delegate from firing.
  public static let interruptionGraceDuration: TimeInterval = 0.25
  public static let presentationSafetyDuration = duration + interruptionGraceDuration
  /// How long a pending send may keep the transcript held before the flight
  /// is forced from whatever geometry is ready. Readiness depends only on
  /// local mounting and measurement, so this is a safety net rather than a
  /// budget the ordinary path ever approaches.
  public static let pendingFlightDeadline: TimeInterval = 1.0
  /// The Core Animation holds' own lifetime. They exist to be replaced by
  /// the flight (or removed by a watchdog) long before this elapses; the
  /// bound only guarantees that a lost watchdog can never leave the model
  /// layer hidden or displaced.
  public static let holdSafetyDuration: TimeInterval = 4.0
  public static let controlPoint1 = CGPoint(x: 0.22, y: 1)
  public static let controlPoint2 = CGPoint(x: 0.36, y: 1)

  /// A new assistant belongs visually after the outgoing user-message
  /// handoff. The pending phase matters as much as the active flight: model
  /// projection can publish the assistant before exact target geometry is
  /// ready, and allowing that row to paint would create a one-frame flash.
  public static func shouldHoldAssistantRow(
    phase: TranscriptSendPresentationPhase,
    rowIsActive: Bool,
    rowExistedBeforeSend: Bool
  ) -> Bool {
    phase != .idle && rowIsActive && !rowExistedBeforeSend
  }

  /// Existing rows stay at their captured viewport coordinates while the
  /// final post-send layout is prepared. The active flight replaces this
  /// static hold with the ordinary translation-to-zero animation.
  public static func shouldHoldHistoryRow(
    phase: TranscriptSendPresentationPhase,
    rowExistedBeforeSend: Bool,
    translationY: CGFloat
  ) -> Bool {
    phase == .pending && rowExistedBeforeSend && abs(translationY) > 1
  }

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

  /// What a pending send does when its deadline passes without the ordinary
  /// readiness gate opening. The flight only needs its destination row laid
  /// out; everything below it is deferred to completion anyway. Without a
  /// laid-out destination there is nothing to fly into, so the held model
  /// state is revealed and the request consumed.
  public static func pendingDeadlineResolution(
    targetIsMounted: Bool,
    targetIsPresentationReady: Bool
  ) -> TranscriptSendPendingDeadlineResolution {
    targetIsMounted && targetIsPresentationReady ? .fly : .reveal
  }
}

public enum TranscriptSendPendingDeadlineResolution: Equatable, Sendable {
  case fly
  case reveal
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
  /// How long a begun presentation may run before its watchdog resolves it.
  public let duration: TimeInterval

  public init(duration: TimeInterval = TranscriptSendAnimationContract.presentationSafetyDuration) {
    self.duration = duration
  }

  @discardableResult
  public mutating func begin(token: UInt64, at time: TimeInterval) -> TimeInterval {
    activeToken = token
    let deadline = time + duration
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
