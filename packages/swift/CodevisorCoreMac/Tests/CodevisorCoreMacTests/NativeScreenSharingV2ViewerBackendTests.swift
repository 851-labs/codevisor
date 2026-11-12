import CodevisorClient
import CodevisorTestSupport
import CustomDump
import Foundation
import ScreenSharing
import ScreenSharingV2
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeScreenSharingV2ViewerBackendTests {
  private func run(_ harness: NativeBackendHarness) async -> [ServerScreenSharingRequest] {
    harness.connect()
    await awaitObserved { harness.log.events.contains(.ready) }
    await harness.cancelConsumers()
    await harness.transport.stopped.wait()
    return await harness.transport.requests
  }

  @Test func aHostThatAdvertisesV2IsStartedOverV2WithTheViewersAddressAndNoOffer() async throws {
    let v2 = NativeBackendHarness.V2()
    let harness = NativeBackendHarness(v2: v2)
    let requests = await run(harness)

    expectNoDifference(requests.map(\.operation), [.capabilities, .start, .stop])
    let start = requests[1]
    #expect(start.engine == "v2")
    #expect(start.media == ScreenSharingViewerFixtures.viewerMedia)
    #expect(v2.grants == [ScreenSharingViewerFixtures.mediaGrant])
    #expect(harness.sessions.map(\.tokens) == [["fixture token"]])
    #expect(harness.sessions[0].presentsTiles, "the Mac pane's renderer draws v2's tiles")
  }

  @Test func aHostWithoutV2EndsWithAnUpdateMessageBeforeStarting() async throws {
    let harness = NativeBackendHarness(transport: SharingTransport(engines: nil))
    await harness.connect().value

    #expect(
      harness.log.events == [
        .ended(
          "The host Mac needs a newer version of Codevisor to share its screen. Update Codevisor on it, then retry.")
      ])
    #expect(await harness.transport.requests.map(\.operation) == [.capabilities])
    #expect(harness.sessions.isEmpty)
  }

  enum V2Failure: CaseIterable, Sendable { case address, hostRefused, connect }

  @Test(arguments: V2Failure.allCases)
  func aFailedFirstV2StartEndsWithAMessage(_ failure: V2Failure) async throws {
    let v2 = NativeBackendHarness.V2()
    v2.hasAddress = failure != .address
    v2.failsConnect = failure == .connect
    let harness = NativeBackendHarness(
      transport: SharingTransport(startStatus: failure == .hostRefused ? "failed" : "connecting"), v2: v2)
    await harness.connect().value
    let requests = await harness.transport.requests

    let expectedMessage =
      failure == .hostRefused
      ? "The host Mac couldn't start sharing its screen. Retry. If it keeps happening, quit and reopen Codevisor on the host Mac."
      : ScreenSharingConnectStage.connectingMedia.failure
    #expect(harness.log.events.last == .ended(expectedMessage))
    let expected: [ServerScreenSharingRequest.Operation] =
      failure == .address ? [.capabilities] : [.capabilities, .start, .stop]
    expectNoDifference(requests.map(\.operation), expected)
    #expect(harness.sessions.isEmpty)
  }

  @Test func aReconnectWhoseConnectFailsTriesAgain() async throws {
    let v2 = NativeBackendHarness.V2()
    let harness = NativeBackendHarness(v2: v2)
    harness.connect()
    await awaitObserved { harness.log.events.contains(.ready) }
    v2.failingConnects = 1
    harness.sessions[0].onConnectionChanged?("failed")
    await awaitObserved { harness.log.events.filter { $0 == .ready }.count == 2 }
    await harness.cancelConsumers()
    await harness.transport.stopped.wait()
    let starts = await harness.transport.requests.filter { [.start, .restart].contains($0.operation) }

    expectNoDifference(starts.map(\.operation), [.start, .restart, .restart])
    #expect(harness.log.events.filter { $0 == .reconnecting }.count == 2)
    #expect(starts.allSatisfy { $0.engine == "v2" })
  }
}
