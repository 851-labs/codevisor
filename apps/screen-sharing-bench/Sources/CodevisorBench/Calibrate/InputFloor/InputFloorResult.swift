import ScreenSharingBench

struct InputFloorResult: Encodable {
  let check = "c6"
  let target: String
  let source: String
  let events: Int
  let stoppedOnLostFocus: Bool
  let unansweredEvents: Int
  let localI2pMs: BenchDistribution?
  let frames: Int
  let unreadableFraction: Double

  private enum CodingKeys: String, CodingKey {
    case check, target, source, events, stoppedOnLostFocus, unansweredEvents, frames, unreadableFraction
    case localI2pMs = "local_i2p_ms"
  }

  init(target: InputFloorTarget, source: String, posted: PostedEvents, observations: [BenchObservation]) {
    let responses = BenchInputResponses(eventsNs: posted.timesNs, observations: observations)
    let versions = BenchObservedVersions(observations)
    self.target = target.rawValue
    self.source = source
    events = posted.timesNs.count
    stoppedOnLostFocus = posted.lostFocus
    unansweredEvents = responses.unansweredEvents
    localI2pMs = BenchDistribution(responses.delaysMs)
    frames = versions.frames
    unreadableFraction = versions.unreadableFraction
  }
}
