enum RendezvousClient {
  private static let retry = Duration.seconds(2)

  @concurrent
  static func meet(
    host: String, port: UInt16, arrival: RendezvousArrival, timeout: Duration
  ) async throws
    -> RendezvousMeeting
  {
    let deadline = ContinuousClock.now + timeout
    let connection = try await SignalingSocket.connect(host: host, port: port, until: deadline, retry: retry)
    try connection.setReceiveTimeout(until: deadline)
    try connection.send(arrival)
    return try connection.receive(RendezvousMeeting.self)
  }
}
