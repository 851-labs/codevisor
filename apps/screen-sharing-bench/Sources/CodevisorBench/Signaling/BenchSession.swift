enum BenchSession {
  static func hold(
    _ connection: SignalingConnection, until deadline: ContinuousClock.Instant, signals: BenchSignalFiles,
    control: SignalingControlChannel
  ) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await control.waitUntilClosed() }
      group.addTask { await signals.waitForStop(until: deadline) }
      await group.next()
      group.cancelAll()
      connection.shutDown()
    }
  }
}
