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

  @Test func webRTCIsUsedWhenTheHostDoesNotAdvertiseV2() async throws {
    let v2 = NativeBackendHarness.V2()
    let harness = NativeBackendHarness(transport: SharingTransport(engines: nil), v2: v2)
    let requests = await run(harness)

    expectNoDifference(requests.map(\.operation), [.capabilities, .start, .stop])
    #expect(requests[1].engine == nil && requests[1].offer == "fixture offer")
    #expect(v2.grants.isEmpty)
  }

  enum V2Failure: CaseIterable, Sendable { case connect, hostEndpoint }

  @Test(arguments: V2Failure.allCases)
  func aFailedV2StartFallsBackToWebRTCForTheRestOfThePane(_ failure: V2Failure) async throws {
    let v2 = NativeBackendHarness.V2()
    v2.failsConnect = failure == .connect
    let harness = NativeBackendHarness(
      transport: SharingTransport(engines: ["v2"], v2StartStatus: failure == .hostEndpoint ? "failed" : "connecting"),
      v2: v2)
    let requests = await run(harness)

    expectNoDifference(requests.map(\.operation), [.capabilities, .start, .capabilities, .start, .stop])
    #expect(requests[1].engine == "v2")
    #expect(requests[3].engine == nil && requests[3].offer == "fixture offer")
    #expect(harness.sessions.count == 1 && harness.sessions[0].answers == ["fixture answer"])
    #expect(!harness.log.events.contains { if case .ended = $0 { true } else { false } })
  }

  enum V2OnlyFailure: CaseIterable, Sendable { case hostWithoutV2, connect }

  @Test(arguments: V2OnlyFailure.allCases)
  func aViewerWithoutWebRTCEndsInsteadOfFallingBack(_ failure: V2OnlyFailure) async throws {
    let v2 = NativeBackendHarness.V2()
    v2.failsConnect = failure == .connect
    let harness = NativeBackendHarness(
      transport: SharingTransport(engines: failure == .hostWithoutV2 ? nil : ["v2"]), v2: v2, webRTC: false)
    await harness.connect().value
    let requests = await harness.transport.requests

    #expect(harness.log.events.contains { if case .ended = $0 { true } else { false } })
    expectNoDifference(
      requests.map(\.operation), failure == .hostWithoutV2 ? [.capabilities] : [.capabilities, .start, .stop])
    #expect(requests.allSatisfy { $0.offer == nil })
    #expect(harness.sessions.isEmpty)
  }

  @Test func aV2SessionWhoseTransportFailsBeforeAnyVideoFallsBackToWebRTC() async throws {
    let harness = NativeBackendHarness(transport: SharingTransport(engines: ["v2"]), v2: NativeBackendHarness.V2())
    harness.configureSession = { [weak harness] session in session.deliversVideo = harness?.sessions.isEmpty == false }
    harness.connect()
    await awaitObserved { harness.log.events.contains { if case .opened = $0 { true } else { false } } }
    harness.sessions[0].onConnectionChanged?("failed")
    await awaitObserved { harness.log.events.contains(.ready) }
    await harness.cancelConsumers()
    await harness.transport.stopped.wait()
    let starts = await harness.transport.requests.filter { [.start, .restart].contains($0.operation) }

    expectNoDifference(starts.map(\.operation), [.start, .start])
    #expect(starts.map(\.engine) == ["v2", nil])
    #expect(starts[1].offer == "fixture offer")
    #expect(!harness.log.events.contains { if case .ended = $0 { true } else { false } })
  }

  @Test func aV2ReconnectThatFailsOnTheHostStartsAFreshWebRTCSessionInsteadOfRestarting() async throws {
    let harness = NativeBackendHarness(
      transport: SharingTransport(engines: ["v2"], v2RestartStatus: "failed"), v2: NativeBackendHarness.V2())
    harness.connect()
    await awaitObserved { harness.log.events.contains(.ready) }
    harness.sessions[0].onConnectionChanged?("failed")
    await awaitObserved { harness.log.events.filter { $0 == .ready }.count == 2 }
    await harness.cancelConsumers()
    await harness.transport.stopped.wait()
    let starts = await harness.transport.requests.filter { [.start, .restart].contains($0.operation) }

    expectNoDifference(starts.map(\.operation), [.start, .restart, .start])
    #expect(starts.map(\.engine) == ["v2", "v2", nil])
    #expect(starts[2].offer == "fixture offer")
  }
}
