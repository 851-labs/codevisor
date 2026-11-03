import CodevisorClient
import CodevisorTestSupport
import CustomDump
import Foundation
import ScreenSharing
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
    let harness = NativeBackendHarness(transport: SharingTransport(engines: ["v2"]), v2: v2)
    let requests = await run(harness)

    expectNoDifference(requests.map(\.operation), [.capabilities, .start, .stop])
    let start = requests[1]
    #expect(start.engine == "v2" && start.offer == nil)
    #expect(start.media == ScreenSharingViewerFixtures.viewerMedia)
    #expect(v2.grants == [ScreenSharingViewerFixtures.mediaGrant])
    #expect(harness.sessions.map(\.tokens) == [["fixture token"]])
    #expect(harness.sessions[0].offers == 0)
  }

  @Test(arguments: [(engines: [String]?.none, enabled: true), (engines: ["v2"], enabled: false)])
  func webRTCIsUsedUnlessBothTheHostAdvertisesAndThisMacChoosesV2(engines: [String]?, enabled: Bool) async throws {
    let v2 = NativeBackendHarness.V2()
    v2.enabled = enabled
    let harness = NativeBackendHarness(transport: SharingTransport(engines: engines), v2: v2)
    let requests = await run(harness)

    expectNoDifference(requests.map(\.operation), [.capabilities, .start, .stop])
    #expect(requests[1].engine == nil && requests[1].offer == "fixture offer")
    #expect(v2.grants.isEmpty)
  }

  @Test func aV2ConnectionThatFailsFallsBackToWebRTCForTheRestOfThePane() async throws {
    let v2 = NativeBackendHarness.V2()
    v2.failsConnect = true
    let harness = NativeBackendHarness(transport: SharingTransport(engines: ["v2"]), v2: v2)
    let requests = await run(harness)

    expectNoDifference(requests.map(\.operation), [.capabilities, .start, .capabilities, .start, .stop])
    #expect(requests[1].engine == "v2")
    #expect(requests[3].engine == nil && requests[3].offer == "fixture offer")
    #expect(harness.sessions.count == 1 && harness.sessions[0].answers == ["fixture answer"])
    #expect(!harness.log.events.contains { if case .ended = $0 { true } else { false } })
  }
}
