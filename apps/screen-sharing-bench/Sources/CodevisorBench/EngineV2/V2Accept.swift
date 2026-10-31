import CodevisorNet

enum V2Accept {
  static func connection(
    on endpoint: NetEndpointHandle, until deadline: ContinuousClock.Instant
  ) async throws -> NetConnectionHandle? {
    let watchdog = Task {
      try await Task.sleep(until: deadline, clock: .continuous)
      await endpoint.close()
    }
    defer { watchdog.cancel() }
    return try await endpoint.accept()
  }
}
