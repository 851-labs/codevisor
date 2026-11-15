enum ComputerUseRemotePreviewTiming {
  static let activePoll: Duration = .seconds(3)
  static let quietPoll: Duration = .seconds(15)
  static let heartbeat: Duration = .seconds(2)

  static func pollInterval(prefersFastPolling: Bool) -> Duration {
    prefersFastPolling ? activePoll : quietPoll
  }
}
