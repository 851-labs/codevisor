import CodevisorClient
import Foundation

/// One automatic retry for a request the host failed only for now (851-2392). A host whose screen
/// capture is stuck restarts it and fails the request that found it stuck; the next request, a
/// couple of seconds later, usually works. Anything else (auth, a missing pane, an old host, a
/// refused offer) fails at once, as before.
public enum ScreenSharingTransientRetry {
  public static let delay: Duration = .seconds(2)

  /// The server's answer when the host app didn't reply in time (851-2391).
  public static func isTransient(_ error: any Error) -> Bool {
    if case CodevisorServerClientError.httpStatus(504, _) = error { return true }
    return false
  }

  /// The host's own answer for a capture start it gave up on (851-2390), in its current wording or
  /// the one alphas 1057–1064 sent.
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
