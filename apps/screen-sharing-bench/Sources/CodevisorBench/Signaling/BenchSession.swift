enum BenchSession {
  static func hold(
    _ connection: SignalingConnection, until deadline: ContinuousClock.Instant, signals: BenchSignalFiles
  ) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await waitForClose(connection) }
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
