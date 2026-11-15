import ComposableArchitecture
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ControlLeaseRevokeTests {
  private static let timedOut = "Control timed out. Request control again."
  private let endpoint = ScreenSharingViewerEndpoint.ID()
  private let lease = UUID()
  private let now = LockIsolated(Date(timeIntervalSinceReferenceDate: 0))

  @Test func aLeaseTheHostTakesBackIsAskedForAgainWithoutABanner() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeControllingStore(client)

      await store.send(.event(.message(.revoked(lease: lease, reason: Self.timedOut))))

      #expect(store.state.phase == .requesting && store.state.wantsControl)
      expectNoDifference(store.state.message, nil)
      expectNoDifference(client.messages(to: endpoint).last, .request(id: UUID(1)))
      expectNoDifference(client.endInputs, [endpoint])
      let regained = UUID()
      await store.send(.event(.message(.grant(request: UUID(1), lease: regained))))
      #expect(store.state.phase == .controlling && store.state.lease == regained)
      expectNoDifference(client.beginInputs.map(\.lease), [lease, regained])
      await store.send(.controlReleased(reason: nil))
    }
  }

  @Test func aLeaseTakenBackAgainRightAwayShowsTheHostsReason() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeControllingStore(client)
      let regained = await regain(store, after: Self.timedOut, with: UUID(1))

      now.withValue { $0 += 3 }
      await store.send(.event(.message(.revoked(lease: regained, reason: "Control ended."))))
      await store.skipReceivedActions(strict: false)

      #expect(store.state.phase == .viewing && !store.state.wantsControl)
      expectNoDifference(store.state.message, "Control ended.")
      expectNoDifference(requests(client), [.request(id: UUID(0)), .request(id: UUID(1))])
    }
  }

  @Test func automaticRetriesStopAtThreeAMinuteAndStartAgainLater() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeControllingStore(client)
      var held = lease
      for retry in 1...3 {
        held = await regain(store, lease: held, after: Self.timedOut, with: UUID(retry))
        now.withValue { $0 += 10 }
      }

      await store.send(.event(.message(.revoked(lease: held, reason: Self.timedOut))))
      await store.skipReceivedActions(strict: false)
      #expect(store.state.phase == .viewing)
      expectNoDifference(store.state.message, Self.timedOut)
      #expect(requests(client).count == 4, "the first request and three automatic retries")

      now.withValue { $0 += 60 }
      await store.send(.controlRequested)
      let again = UUID()
      await store.send(.event(.message(.grant(request: UUID(4), lease: again))))
      await store.send(.event(.message(.revoked(lease: again, reason: Self.timedOut))))
      #expect(store.state.phase == .requesting, "a minute later the host taking it back is retried again")
      await store.send(.controlReleased(reason: nil))
    }
  }

  @Test(arguments: [true, false])
  func aRetryThatFailsShowsWhyTheHostTookControlBack(refused: Bool) async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let clock = Clocks.TestClock()
      let store = await makeControllingStore(client, clock: clock)
      await store.send(.event(.message(.revoked(lease: lease, reason: "The host's screen capture stopped."))))

      if refused {
        let refusal = "Wait for live video before requesting control."
        await store.send(.event(.message(.denied(request: UUID(1), reason: refusal))))
      } else {
        await clock.advance(by: .seconds(6))
      }
      await store.skipReceivedActions(strict: false)

      #expect(store.state.phase == .viewing)
      expectNoDifference(store.state.message, "The host's screen capture stopped.")
      expectNoDifference(store.state.revokeReason, nil)
    }
  }

  @Test(arguments: [true, false])
  func aLeaseGivenBackOnPurposeIsNotAskedForAgain(byHiding: Bool) async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeControllingStore(client)
      await store.send(byHiding ? .suspended : .controlReleased(reason: nil))
      await store.skipReceivedActions(strict: false)

      await store.send(.event(.message(.revoked(lease: lease, reason: "Control released."))))

      #expect(store.state.phase == .viewing)
      expectNoDifference(store.state.message, nil)
      expectNoDifference(client.messages(to: endpoint), [.request(id: UUID(0)), .release(lease: lease)])
    }
  }

  private func requests(_ client: FakeEndpointClient) -> [ScreenSharingControlMessage] {
    client.messages(to: endpoint).filter { if case .request = $0 { true } else { false } }
  }

  private func regain(
    _ store: TestStoreOf<ControlLease>, lease held: UUID? = nil, after reason: String, with request: UUID
  ) async -> UUID {
    let regained = UUID()
    await store.send(.event(.message(.revoked(lease: held ?? lease, reason: reason))))
    await store.send(.event(.message(.grant(request: request, lease: regained))))
    return regained
  }

  private func makeControllingStore(
    _ client: FakeEndpointClient, clock: Clocks.TestClock<Duration> = Clocks.TestClock()
  ) async -> TestStoreOf<ControlLease> {
    let store = TestStore(initialState: ControlLease.State(endpoint: endpoint)) {
      ControlLease()
    } withDependencies: { [now] in
      $0[ScreenSharingEndpointClient.self] = client.value
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.date = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.event(.availability(true)))
    await store.send(.controlRequested)
    await store.send(.event(.message(.grant(request: UUID(0), lease: lease))))
    return store
  }
}
