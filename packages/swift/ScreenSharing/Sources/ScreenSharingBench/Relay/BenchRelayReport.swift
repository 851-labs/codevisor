public struct BenchRelayReport: Codable, Sendable, Equatable {
  public var media: BenchRelayStatistics
  public var feedback: BenchRelayStatistics

  public init(media: BenchRelayStatistics, feedback: BenchRelayStatistics) {
    self.media = media
    self.feedback = feedback
  }
}
