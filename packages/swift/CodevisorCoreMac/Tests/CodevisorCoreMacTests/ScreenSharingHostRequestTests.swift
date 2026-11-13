import CodevisorClient
import CodevisorCore
import CoreGraphics
import CodevisorTestSupport
import Foundation
import ScreenSharingV2
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostRequestTests {
  @Test func stopDuringInitialDisplayLookupPreventsTheStartFromContinuing() async {
    let entered = TestSignal()
    let release = TestSignal()
    let host = makeHost {
      entered.signal()
      await release.wait()
      return []
    }
    let start = request()
    let pending = Task { await host.handle(start) }
    await entered.wait()
    let stopped = await host.handle(stop(start))
    #expect(stopped.status == "stopped")
    release.signal()
    let result = await pending.value
    #expect(result.status == "stopped")
    await host.shutdown()
  }

  @Test func aLaterExplicitStartIsNotCancelledByTheEarlierStop() async {
    let entered = TestSignal()
    let release = TestSignal()
    var lookups = 0
    let host = makeHost {
      lookups += 1
      entered.signal()
      await release.wait()
      return []
    }
    let start = request()
    let pending = Task { await host.handle(start) }
    await entered.wait()
    _ = await host.handle(stop(start))
    release.signal()
    #expect(await pending.value.status == "stopped")
    let next = await host.handle(start)
    #expect(next.status == "unavailable")
    #expect(lookups == 2)
    await host.shutdown()
  }

  @Test func aRepeatedStartFromTheSamePaneSupersedesTheOneStillPending() async {
    let entered = TestSignal()
    let release = TestSignal()
    let host = makeHost {
      entered.signal()
      await release.wait()
      return []
    }
    let start = request()
    let first = Task { await host.handle(start) }
    await entered.wait()
    let retried = Task { await host.handle(start) }
    await entered.wait(for: 2)
    release.signal()
    #expect(await first.value.status == "stopped")
    #expect(await retried.value.status == "unavailable")
    await host.shutdown()
  }

  enum ForeignIdentity: CaseIterable, Sendable { case workspace, pane, viewer }

  @Test(arguments: ForeignIdentity.allCases)
  func anotherOwnersStopDoesNotCancelThePendingStart(_ identity: ForeignIdentity) async {
    let entered = TestSignal()
    let release = TestSignal()
    let host = makeHost {
      entered.signal()
      await release.wait()
      return []
    }
    let start = request()
    let pending = Task { await host.handle(start) }
    await entered.wait()
    let foreign = ServerScreenSharingRequest(
      operation: .stop, workspaceId: identity == .workspace ? UUID() : start.workspaceId,
      paneId: identity == .pane ? UUID() : start.paneId,
      viewerId: identity == .viewer ? UUID() : start.viewerId)
    _ = await host.handle(foreign)
    release.signal()
    #expect(await pending.value.status == "unavailable")
    await host.shutdown()
  }

  @Test func stoppingOneOfTwoPendingOwnersDoesNotCancelTheOther() async {
    let entered = TestSignal()
    let release = TestSignal()
    let host = makeHost {
      entered.signal()
      await release.wait()
      return []
    }
    let first = request()
    let second = request()
    let pendingFirst = Task { await host.handle(first) }
    await entered.wait()
    let pendingSecond = Task { await host.handle(second) }
    await entered.wait(for: 2)
    _ = await host.handle(stop(first))
    release.signal()
    #expect(await pendingFirst.value.status == "stopped")
    #expect(await pendingSecond.value.status == "unavailable")
    await host.shutdown()
  }

  @Test func shutdownInvalidatesPendingDisplayLookup() async {
    let entered = TestSignal()
    let release = TestSignal()
    let host = makeHost {
      entered.signal()
      await release.wait()
      return []
    }
    let start = request()
    let pending = Task { await host.handle(start) }
    await entered.wait()
    await host.shutdown()
    release.signal()
    #expect(await pending.value.status == "stopped")
    #expect(await host.handle(start).status == "stopped")
  }

  @Test func aSystemStopInvalidatesEveryPendingOwner() async {
    let entered = TestSignal()
    let release = TestSignal()
    let host = makeHost {
      entered.signal()
      await release.wait()
      return []
    }
    let first = request()
    let second = request()
    let pendingFirst = Task { await host.handle(first) }
    await entered.wait()
    let pendingSecond = Task { await host.handle(second) }
    await entered.wait(for: 2)
    host.systemStopped(.displayAsleep)
    release.signal()
    #expect(await pendingFirst.value.status == "stopped")
    #expect(await pendingSecond.value.status == "stopped")
    #expect(await host.handle(request()).status == "unavailable")
    await host.shutdown()
  }

  @Test func onlyAHostWithAMediaEndpointAdvertisesEngineV2() async {
    let plain = makeHost(mediaEndpoint: ScreenSharingMediaEndpoint()) { [] }
    let capable = makeHost { [] }
    #expect(await plain.handle(capabilities()).engines == nil)
    #expect(await capable.handle(capabilities()).engines == ["v2"])
    await plain.shutdown()
    await capable.shutdown()
  }

  @Test func aV2StartIsRefusedByAHostWithoutAMediaEndpoint() async {
    let host = makeHost(mediaEndpoint: ScreenSharingMediaEndpoint()) { [self.display] }
    let reply = await host.handle(request())
    #expect(reply.status == "failed" && reply.media == nil)
    #expect(reply.message == "This Mac's screen-sharing endpoint isn't available.")
    #expect(await host.handle(capabilities()).status == "available")
    await host.shutdown()
  }

  @Test func aV2StartWhoseEndpointCantBindFailsAndLeavesTheHostFree() async {
    let host = makeHost { [self.display] }
    let reply = await host.handle(request())
    #expect(reply.status == "failed")
    #expect(reply.message == "This Mac's screen-sharing endpoint isn't available.")
    #expect(await host.handle(capabilities()).status == "available")
    await host.shutdown()
  }

  private var display: ScreenSharingHostService.Display {
    (CGMainDisplayID(), ServerScreenSharingDisplay(id: "display", name: "Display", width: 1280, height: 720))
  }

  private static func unboundEndpoint() -> ScreenSharingMediaEndpoint {
    let endpoint = ScreenSharingMediaEndpoint()
    endpoint.configure { nil }
    return endpoint
  }

  private func capabilities() -> ServerScreenSharingRequest {
    .init(operation: .capabilities, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
  }

  private func request() -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID(), displayId: "display")
    request.engine = "v2"
    request.media = .init(endpointId: String(repeating: "a", count: 64), relayUrl: nil, directAddrs: [])
    return request
  }

  private func makeHost(
    mediaEndpoint: ScreenSharingMediaEndpoint = ScreenSharingHostRequestTests.unboundEndpoint(),
    enumerate: @escaping () async throws -> [ScreenSharingHostService.Display]
  ) -> ScreenSharingHostService {
    ScreenSharingHostService(
      captureAccess: { true }, notificationCenter: NotificationCenter(),
      workspaceNotificationCenter: NotificationCenter(), enumerateDisplays: enumerate, mediaEndpoint: mediaEndpoint)
  }

  private func stop(_ start: ServerScreenSharingRequest) -> ServerScreenSharingRequest {
    .init(operation: .stop, workspaceId: start.workspaceId, paneId: start.paneId, viewerId: start.viewerId)
  }
}
