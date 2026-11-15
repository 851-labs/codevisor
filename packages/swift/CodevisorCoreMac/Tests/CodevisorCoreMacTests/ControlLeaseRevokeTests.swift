import ComposableArchitecture
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ControlLeaseRevokeTests {
  private let endpoint = ScreenSharingViewerEndpoint.ID()
  private let lease = UUID()
  private let regained = UUID()

  @Test func aLeaseTheHostTakesBackIsAskedForAgainOnceWithoutABanner() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let clock = Clocks.TestClock()
      let store = await makeControllingStore(client, clock: clock)

      await store.send(.event(.message(.revoked(lease: lease, reason: "Control timed out. Request control again."))))

      #expect(store.state.phase == .requesting && store.state.wantsControl)
      expectNoDifference(store.state.message, nil)
      expectNoDifference(client.messages(to: endpoint).last, .request(id: UUID(1)))
      expectNoDifference(client.endInputs, [endpoint])
      await store.send(.event(.message(.grant(request: UUID(1), lease: regained))))
      #expect(store.state.phase == .controlling && store.state.lease == regained)
      expectNoDifference(client.beginInputs.map(\.lease), [lease, regained])

      await clock.advance(by: .seconds(4))
      await store.skipReceivedActions(strict: false)
      #expect(!store.state.retriedAfterRevoke, "a lease that held is allowed one more retry later")
      await store.send(.controlReleased(reason: nil))
    }
  }

  @Test func aLeaseTakenBackAgainRightAwayShowsTheHostsReason() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeControllingStore(client, clock: Clocks.TestClock())
      await store.send(.event(.message(.revoked(lease: lease, reason: "Control timed out. Request control again."))))
      await store.send(.event(.message(.grant(request: UUID(1), lease: regained))))

      await store.send(.event(.message(.revoked(lease: regained, reason: "Control timed out. Request control again."))))
      await store.skipReceivedActions(strict: false)

      #expect(store.state.phase == .viewing && !store.state.wantsControl)
      expectNoDifference(store.state.message, "Control timed out. Request control again.")
      let requests = client.messages(to: endpoint).filter { if case .request = $0 { true } else { false } }
      expectNoDifference(requests, [.request(id: UUID(0)), .request(id: UUID(1))])
    }
  }

  @Test func aRefusedRetryShowsTheHostsReason() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeControllingStore(client, clock: Clocks.TestClock())
      await store.send(.event(.message(.revoked(lease: lease, reason: "Control timed out. Request control again."))))

      await store.send(.event(.message(.denied(request: UUID(1), reason: "Allow Codevisor in Accessibility."))))
      await store.skipReceivedActions(strict: false)

      #expect(store.state.phase == .viewing)
      expectNoDifference(store.state.message, "Allow Codevisor in Accessibility.")
      #expect(!store.state.retriedAfterRevoke)
    }
  }

  @Test(arguments: [true, false])
  func aLeaseGivenBackOnPurposeIsNotAskedForAgain(byHiding: Bool) async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeControllingStore(client, clock: Clocks.TestClock())
      await store.send(byHiding ? .suspended : .controlReleased(reason: nil))
      await store.skipReceivedActions(strict: false)

      await store.send(.event(.message(.revoked(lease: lease, reason: "Control released."))))

      #expect(store.state.phase == .viewing)
      expectNoDifference(store.state.message, nil)
      expectNoDifference(client.messages(to: endpoint), [.request(id: UUID(0)), .release(lease: lease)])
    }
  }

  private func makeControllingStore(
    _ client: FakeEndpointClient, clock: Clocks.TestClock<Duration>
  ) async -> TestStoreOf<ControlLease> {
    let store = TestStore(initialState: ControlLease.State(endpoint: endpoint)) {
      ControlLease()
    } withDependencies: {
      $0[ScreenSharingEndpointClient.self] = client.value
      $0.continuousClock = clock
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.event(.availability(true)))
    await store.send(.controlRequested)
    await store.send(.event(.message(.grant(request: UUID(0), lease: lease))))
    return store
  }
}
