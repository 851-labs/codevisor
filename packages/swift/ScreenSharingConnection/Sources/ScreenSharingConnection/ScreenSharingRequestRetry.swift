import CodevisorClient

@MainActor
enum ScreenSharingRequestRetry {
  static func run<Value>(
    sleep: @Sendable (Duration) async throws -> Void, _ request: () async throws -> Value
  ) async throws -> Value {
    for delay in ServerConnectionLoss.interruptionRetryDelays {
      do {
        return try await request()
      } catch  where isTransient(error) {
        try await sleep(delay)
      }
    }
    return try await request()
  }

  static func isTransient(_ error: any Error) -> Bool {
    if case CodevisorServerClientError.httpStatus(504, _) = error { return true }
    return ServerConnectionLoss.isInterruption(error)
  }
}
