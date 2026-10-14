import CodevisorClient
import Foundation

public enum ScreenSharingTransientRetry {
  public static let delay: Duration = .seconds(2)

  public static func isTransient(_ error: any Error) -> Bool {
    if case CodevisorServerClientError.httpStatus(504, _) = error { return true }
    return false
  }

  public static func isTransient(_ reply: ServerScreenSharingReply) -> Bool {
    [
      ScreenSharingCaptureStallRecovery.stuck.localizedDescription,
      "This Mac's screen capture isn't responding. Try again in a minute.",
    ].contains(reply.message)
  }

  @MainActor public static func run(
    sleep: @Sendable (Duration) async throws -> Void,
    _ request: @MainActor () async throws -> ServerScreenSharingReply
  ) async throws -> ServerScreenSharingReply {
    do {
      let reply = try await request()
      guard isTransient(reply) else { return reply }
    } catch  where isTransient(error) {
    }
    try await sleep(delay)
    return try await request()
  }
}
