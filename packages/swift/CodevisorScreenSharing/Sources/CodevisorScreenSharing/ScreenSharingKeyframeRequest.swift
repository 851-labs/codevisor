/// Owned by the encoder lock. One forced encode attempt may be in flight;
/// failed attempts retain the request, and old output cannot clear a new one.
struct ScreenSharingKeyframeRequest {
  struct Attempt: Equatable, Sendable {
    fileprivate let id: UInt64
    fileprivate let generation: UInt64
  }

  private var requested: UInt64 = 0
  private var fulfilled: UInt64 = 0
  private var nextAttempt: UInt64 = 0
  private var inFlight: Attempt?

  var isPending: Bool { requested != fulfilled }

  mutating func request() { requested &+= 1 }

  mutating func beginAttempt() -> Attempt? {
    guard isPending, inFlight == nil else { return nil }
    nextAttempt &+= 1
    let attempt = Attempt(id: nextAttempt, generation: requested)
    inFlight = attempt
    return attempt
  }

  /// Returns true when this attempt failed and a later frame must retry it.
  @discardableResult
  mutating func complete(_ attempt: Attempt?, producedKeyFrame: Bool) -> Bool {
    guard let attempt, inFlight == attempt else { return false }
    inFlight = nil
    if producedKeyFrame { fulfilled = attempt.generation }
    return !producedKeyFrame
  }
}
