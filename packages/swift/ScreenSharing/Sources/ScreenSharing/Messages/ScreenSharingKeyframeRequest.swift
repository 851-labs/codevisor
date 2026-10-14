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

  @discardableResult
  mutating func complete(_ attempt: Attempt?, producedKeyFrame: Bool) -> Bool {
    guard let attempt, inFlight == attempt else { return false }
    inFlight = nil
    if producedKeyFrame { fulfilled = attempt.generation }
    return !producedKeyFrame
  }
}
