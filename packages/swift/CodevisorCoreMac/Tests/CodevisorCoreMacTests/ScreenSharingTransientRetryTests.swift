import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCoreMac

/// 851-2392: the host's first answer after it found its capture stuck fails, the next one a few
/// seconds later works; the viewer tries once more by itself instead of showing Retry.
@MainActor
struct ScreenSharingTransientRetryTests {
  /// Replies (or errors) handed out in order; counts the requests.
  @MainActor final class Script {
    var outcomes: [Result<ServerScreenSharingReply, any Error>]
    private(set) var requests = 0
    init(_ outcomes: [Result<ServerScreenSharingReply, any Error>]) { self.outcomes = outcomes }
    func next() throws -> ServerScreenSharingReply {
      requests += 1
      return try outcomes.removeFirst().get()
    }
  }

  static let available = ServerScreenSharingReply(status: "available")
  static let stuck = ServerScreenSharingReply(
    status: "failed", message: ScreenSharingCaptureStallRecovery.stuck.localizedDescription)
  static let timedOut = CodevisorServerClientError.httpStatus(504, #"{"error":"timed out"}"#)

  func run(_ script: Script, clock: TestClock) -> Task<ServerScreenSharingReply, any Error> {
    Task { try await ScreenSharingTransientRetry.run(sleep: { try await clock.sleep(for: $0) }) { try script.next() } }
  }

  @Test func aTimedOutHostIsAskedOnceMoreAfterTwoSeconds() async throws {
    let clock = TestClock()
    let script = Script([.failure(Self.timedOut), .success(Self.available)])
    let task = run(script, clock: clock)
    await clock.waitForSleep(.seconds(2))
    #expect(script.requests == 1)
    clock.advance(by: .seconds(2))
    #expect(try await task.value.status == "available")
    #expect(script.requests == 2)
  }

  @Test func aHostWhoseCaptureIsStuckIsAskedOnceMore() async throws {
    let clock = TestClock()
    let script = Script([.success(Self.stuck), .success(Self.available)])
    let task = run(script, clock: clock)
    await clock.waitForSleep(.seconds(2))
    clock.advance(by: .seconds(2))
    #expect(try await task.value.status == "available")
  }

  @Test func onlyOnceTheSecondAnswerStands() async throws {
    let clock = TestClock()
    let script = Script([.failure(Self.timedOut), .failure(Self.timedOut), .success(Self.available)])
    let task = run(script, clock: clock)
    await clock.waitForSleep(.seconds(2))
    clock.advance(by: .seconds(2))
    await #expect(throws: CodevisorServerClientError.self) { try await task.value }
    #expect(script.requests == 2)
  }

  @Test func permanentFailuresAndAnswersAreNotRetried() async throws {
    let clock = TestClock()
    for outcome: Result<ServerScreenSharingReply, any Error> in [
      .failure(CodevisorServerClientError.httpStatus(503, #"{"error":"Open or update Codevisor"}"#)),
      .failure(CodevisorServerClientError.httpStatus(404, "")),
      .failure(URLError(.notConnectedToInternet)),
      .success(ServerScreenSharingReply(status: "unavailable", message: "This Mac can't share its screen.")),
      .success(Self.available),
    ] {
      let script = Script([outcome])
      _ = try? await run(script, clock: clock).value
      #expect(script.requests == 1)
    }
    #expect(clock.pendingCount == 0)
  }
}
