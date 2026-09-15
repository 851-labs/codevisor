import CodevisorCore
import CodevisorTestSupport
import Foundation
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
    // An empty enumeration deliberately avoids creating a native peer. Reaching display selection at all is wrong
    // after Stop; the same continuation with an available display would otherwise construct a live media session.
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
    // The signal remains open. A newly issued Start, even for the same owner, gets its own admission.
    let next = await host.handle(start)
    #expect(next.status == "unavailable")
    #expect(lookups == 2)
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
    // Display selection is reached: a different workspace, pane or viewer cannot cancel this owner.
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
    // Exercise the same main-actor entry as the OS notification adapter without posting a process-global event.
    host.systemStopped()
    release.signal()
    #expect(await pendingFirst.value.status == "stopped")
    #expect(await pendingSecond.value.status == "stopped")
    // A system stop invalidates attempts already admitted; it does not shut down the host service permanently.
    #expect(await host.handle(request()).status == "unavailable")
    await host.shutdown()
  }

  private func makeHost(
    enumerate: @escaping () async throws -> [ScreenSharingHostService.Display]
  ) -> ScreenSharingHostService {
    ScreenSharingHostService(
      captureAccess: { true }, notificationCenter: NotificationCenter(),
      workspaceNotificationCenter: NotificationCenter(), enumerateDisplays: enumerate)
  }

  private func request() -> ServerScreenSharingRequest {
    .init(
      operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID(), displayId: "display",
      offer: "a=fingerprint:sha-256 fixture")
  }

  private func stop(_ start: ServerScreenSharingRequest) -> ServerScreenSharingRequest {
    .init(operation: .stop, workspaceId: start.workspaceId, paneId: start.paneId, viewerId: start.viewerId)
  }
}
