import ScreenSharing
import ComposableArchitecture
import Foundation
import Testing
@testable import CodevisorCoreMac

/// The viewer's lease state machine over a scripted endpoint client: request
/// gating on channel availability, denial, revocation, the grant deadline,
/// heartbeats, and every path that gives control back.
@MainActor
struct ControlLeaseTests {
  private let endpoint = ScreenSharingViewerEndpoint.ID()
  private let lease = UUID()

  @Test func initialRequestWaitsForAvailabilityAndDoesNotRetryADenial() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = makeStore(client)
      await store.send(.controlRequested) { $0.wantsControl = true }
      await store.send(.event(.availability(false)))
      expectNoDifference(client.messages(to: endpoint), [])
      await store.send(.event(.availability(true))) {
        $0.available = true
        $0.requestID = UUID(0)
        $0.phase = .requesting
      }
      await store.send(.event(.availability(true)))
      expectNoDifference(client.messages(to: endpoint), [.request(id: UUID(0))])
      await store.send(.event(.message(.denied(request: UUID(0), reason: "Accessibility required")))) {
        $0.wantsControl = false
        $0.requestID = nil
        $0.phase = .viewing
        $0.message = "Accessibility required"
      }
      await store.receive(\.delegate.released)
      await store.send(.event(.availability(false))) {
        $0.available = false
        $0.message = "Control is unavailable on this connection."
      }
      await store.send(.event(.availability(true))) {
        $0.available = true
        $0.message = nil
      }
      expectNoDifference(client.messages(to: endpoint), [.request(id: UUID(0))])
      await store.send(.controlRequested) {
        $0.wantsControl = true
        $0.requestID = UUID(1)
        $0.phase = .requesting
      }
      expectNoDifference(client.messages(to: endpoint), [.request(id: UUID(0)), .request(id: UUID(1))])
      await store.send(.controlReleased(reason: nil)) {
        $0.wantsControl = false
        $0.requestID = nil
        $0.phase = .viewing
      }
      await store.receive(\.delegate.released)
    }
  }

  @Test func releaseCancelsAnInitialRequestBeforeTheChannelOpens() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = makeStore(client)
      await store.send(.controlRequested) { $0.wantsControl = true }
      await store.send(.controlReleased(reason: nil)) { $0.wantsControl = false }
      await store.send(.event(.availability(true))) { $0.available = true }
      expectNoDifference(client.messages(to: endpoint), [])
      expectNoDifference(client.endInputs, [endpoint])
    }
  }

  @Test func cancelledAndTimedOutRequestsReleaseLateGrants() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let clock = Clocks.TestClock()
      let store = makeStore(client, clock: clock)
      await store.send(.event(.availability(true))) { $0.available = true }
      await store.send(.controlRequested) {
        $0.wantsControl = true
        $0.requestID = UUID(0)
        $0.phase = .requesting
      }
      await store.send(.controlReleased(reason: nil)) {
        $0.wantsControl = false
        $0.requestID = nil
        $0.phase = .viewing
      }
      await store.receive(\.delegate.released)
      await store.send(.event(.message(.grant(request: UUID(0), lease: lease))))
      expectNoDifference(client.messages(to: endpoint).last, .release(lease: lease))
      await store.send(.controlRequested) {
        $0.wantsControl = true
        $0.requestID = UUID(1)
        $0.phase = .requesting
      }
      await clock.advance(by: .seconds(3))
      await store.receive(\.requestTimedOut) {
        $0.wantsControl = false
        $0.requestID = nil
        $0.phase = .viewing
        $0.message = "The host did not grant control. Try again."
      }
      await store.receive(\.delegate.released)
      await store.send(.event(.message(.grant(request: UUID(1), lease: lease))))
      expectNoDifference(client.messages(to: endpoint).last, .release(lease: lease))
      expectNoDifference(client.beginInputs.count, 0)
    }
  }

  @Test func aGrantStartsInputAndHeartbeatsUntilTheChannelFails() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let clock = Clocks.TestClock()
      let store = await makeControllingStore(client, clock: clock)
      expectNoDifference(client.beginInputs.map(\.lease), [lease])
      await clock.advance(by: .seconds(1))
      await store.receive(\.heartbeatTick)
      expectNoDifference(client.messages(to: endpoint).last, .heartbeat(lease: lease))
      client.sendSucceeds = false
      await clock.advance(by: .seconds(1))
      await store.receive(\.heartbeatTick)
      await store.receive(\.channelSendFailed) {
        $0.wantsControl = false
        $0.lease = nil
        $0.phase = .viewing
        $0.message = "The control channel closed."
      }
      await store.receive(\.delegate.released)
      expectNoDifference(client.endInputs, [endpoint])
      expectNoDifference(client.messages(to: endpoint).last, .release(lease: lease))
      await clock.advance(by: .seconds(5))
    }
  }

  @Test(arguments: [
    ScreenSharingControlEvent.inputLost("Keyboard capture stopped."),
    .sessionFailed("Video decoding failed. Reconnect before controlling."),
  ])
  func inputLossAndSessionFailureGiveControlBack(event: ScreenSharingControlEvent) async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeControllingStore(client)
      let reason: String? =
        switch event {
        case .inputLost(let reason): reason
        case .sessionFailed(let reason): reason
        default: nil
        }
      await store.send(.event(event)) {
        $0.wantsControl = false
        $0.lease = nil
        $0.phase = .viewing
        $0.message = reason
      }
      await store.receive(\.delegate.released)
      expectNoDifference(client.endInputs, [endpoint])
      expectNoDifference(client.messages(to: endpoint).last, .release(lease: lease))
    }
  }

  @Test func revocationOfAnotherLeaseIsIgnoredAndOfThisOneReleases() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeControllingStore(client)
      await store.send(.event(.message(.revoked(lease: UUID(), reason: "Someone else's lease"))))
      await store.send(.event(.message(.revoked(lease: lease, reason: "Host ended control")))) {
        $0.wantsControl = false
        $0.lease = nil
        $0.phase = .viewing
        $0.message = "Host ended control"
      }
      await store.receive(\.delegate.released)
      expectNoDifference(client.endInputs, [endpoint])
    }
  }

  @Test func aRefusedInputCaptureReleasesWithTheSurfaceMessage() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      client.beginInputFailure = "Focus this window and request control again."
      let store = makeStore(client)
      await store.send(.event(.availability(true))) { $0.available = true }
      await store.send(.controlRequested) {
        $0.wantsControl = true
        $0.requestID = UUID(0)
        $0.phase = .requesting
      }
      await store.send(.event(.message(.grant(request: UUID(0), lease: lease)))) {
        $0.requestID = nil
        $0.lease = self.lease
        $0.phase = .controlling
      }
      await store.receive(\.event.inputLost) {
        $0.wantsControl = false
        $0.lease = nil
        $0.phase = .viewing
        $0.message = "Focus this window and request control again."
      }
      await store.receive(\.delegate.released)
      expectNoDifference(client.messages(to: endpoint).last, .release(lease: lease))
    }
  }

  private func makeStore(
    _ client: FakeEndpointClient, clock: any Clock<Duration> = Clocks.TestClock()
  ) -> TestStoreOf<ControlLease> {
    TestStore(initialState: ControlLease.State(endpoint: endpoint)) {
      ControlLease()
    } withDependencies: {
      $0[ScreenSharingEndpointClient.self] = client.value
      $0.continuousClock = clock
      $0.uuid = .incrementing
    }
  }

  /// Available channel, request sent and granted with `lease`.
  private func makeControllingStore(
    _ client: FakeEndpointClient, clock: any Clock<Duration> = Clocks.TestClock()
  ) async -> TestStoreOf<ControlLease> {
    let store = makeStore(client, clock: clock)
    await store.send(.event(.availability(true))) { $0.available = true }
    await store.send(.controlRequested) {
      $0.wantsControl = true
      $0.requestID = UUID(0)
      $0.phase = .requesting
    }
    await store.send(.event(.message(.grant(request: UUID(0), lease: lease)))) {
      $0.requestID = nil
      $0.lease = self.lease
      $0.phase = .controlling
    }
    return store
  }
}
