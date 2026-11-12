import CodevisorClient
import CodevisorCloud
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingTransientRetryTests {
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

  @Test func aHostOnTheEarlierWordingIsAskedOnceMoreToo() async throws {
    let clock = TestClock()
    let earlier = ServerScreenSharingReply(
      status: "failed", message: "This Mac's screen capture isn't responding. Try again in a minute.")
    let script = Script([.success(earlier), .success(Self.available)])
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

  static let interrupted = CloudRelayTransportError.channelClosed(nil)

  @Test func aRelayChannelThatClosesWithNoReasonIsRetriedAfterHalfASecond() async throws {
    let clock = TestClock()
    let script = Script([.failure(Self.interrupted), .success(Self.available)])
    let task = run(script, clock: clock)
    await clock.waitForSleep(.milliseconds(500))
    #expect(script.requests == 1)
    clock.advance(by: .milliseconds(500))
    #expect(try await task.value.status == "available")
    #expect(script.requests == 2)
  }

  @Test func aRelayThatKeepsDroppingFailsAfterThreeTries() async throws {
    let clock = TestClock()
    let script = Script([.failure(Self.interrupted), .failure(Self.interrupted), .failure(Self.interrupted)])
    let task = run(script, clock: clock)
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(500))
    await clock.waitForSleep(.seconds(1))
    clock.advance(by: .seconds(1))
    await #expect(throws: CloudRelayTransportError.channelClosed(nil)) { try await task.value }
    #expect(script.requests == 3)
  }

  @Test func aRequestThatReachesAPipeAlreadyDownIsRetriedToo() async throws {
    let clock = TestClock()
    let script = Script([.failure(CloudHubConnectionError.disconnected), .success(Self.available)])
    let task = run(script, clock: clock)
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(500))
    #expect(try await task.value.status == "available")
  }

  @Test func dropsAndATimedOutHostShareOneBudgetOfFourRequests() async throws {
    let clock = TestClock()
    let script = Script([
      .failure(Self.interrupted), .failure(Self.timedOut), .failure(Self.interrupted), .failure(Self.interrupted),
    ])
    let task = run(script, clock: clock)
    for delay: Duration in [.milliseconds(500), .seconds(2), .seconds(1)] {
      await clock.waitForSleep(delay)
      clock.advance(by: delay)
    }
    await #expect(throws: CloudRelayTransportError.channelClosed(nil)) { try await task.value }
    #expect(script.requests == 4)
  }

  @Test func permanentFailuresAndAnswersAreNotRetried() async throws {
    let clock = TestClock()
    for outcome: Result<ServerScreenSharingReply, any Error> in [
      .failure(CodevisorServerClientError.httpStatus(503, #"{"error":"Open or update Codevisor"}"#)),
      .failure(CodevisorServerClientError.httpStatus(404, "")),
      .failure(URLError(.notConnectedToInternet)),
      .failure(CloudRelayTransportError.channelClosed(.rejected)),
      .failure(CloudRelayTransportError.timedOut),
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
