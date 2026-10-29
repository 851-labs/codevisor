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
