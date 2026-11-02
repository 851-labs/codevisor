enum BenchSession {
  static func hold(
    _ connection: SignalingConnection, until deadline: ContinuousClock.Instant, signals: BenchSignalFiles,
    control: SignalingControlChannel? = nil
  ) async {
    await withTaskGroup(of: Void.self) { group in
      if let control {
        group.addTask { await control.waitUntilClosed() }
      } else {
        group.addTask { await waitForClose(connection) }
      }
      group.addTask { await signals.waitForStop(until: deadline) }
      await group.next()
      group.cancelAll()
      connection.shutDown()
    }
  }

  @concurrent
  private static func waitForClose(_ connection: SignalingConnection) async {
    connection.waitForClose()
  }
}
