import ComposableArchitecture
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ControlLeaseRequestTests {
  private let endpoint = ScreenSharingViewerEndpoint.ID()
  private let lease = UUID()

  @Test func aRequestWithNoAnswerIsSentOnceMoreBeforeThePaneSaysSo() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let clock = Clocks.TestClock()
      let store = await makeRetryingStore(client, clock: clock)

      #expect(store.state.message == nil)
      expectNoDifference(client.messages(to: endpoint), [.request(id: UUID(0)), .request(id: UUID(1))])
      await store.send(.event(.message(.grant(request: UUID(1), lease: lease)))) {
        $0.requestID = nil
        $0.retriedRequest = false
        $0.lease = self.lease
        $0.phase = .controlling
      }
      expectNoDifference(client.beginInputs.map(\.lease), [lease])
      await clock.advance(by: .seconds(3))
      await store.receive(\.heartbeatTick)
      await store.receive(\.heartbeatTick)
      await store.receive(\.heartbeatTick)
      await store.send(.controlReleased(reason: nil)) {
        $0.wantsControl = false
        $0.lease = nil
        $0.phase = .viewing
      }
      await store.receive(\.delegate.released)
    }
  }

  @Test func aLateGrantForTheFirstRequestIsTakenAndTheSecondRequestsRefusalIsNotShown() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeRetryingStore(client, clock: Clocks.TestClock())

      await store.send(.event(.message(.grant(request: UUID(0), lease: lease)))) {
        $0.requestID = nil
        $0.retriedRequest = false
        $0.unansweredRequests = [UUID(1)]
        $0.lease = self.lease
        $0.phase = .controlling
      }
      await store.send(.event(.message(.denied(request: UUID(1), reason: "Control is already active.")))) {
        $0.unansweredRequests = []
      }

      #expect(store.state.message == nil)
      expectNoDifference(client.beginInputs.map(\.lease), [lease])
      expectNoDifference(client.messages(to: endpoint), [.request(id: UUID(0)), .request(id: UUID(1))])
      await store.send(.controlReleased(reason: nil)) {
        $0.wantsControl = false
        $0.lease = nil
        $0.phase = .viewing
      }
      await store.receive(\.delegate.released)
    }
  }

  @Test func aGrantForARequestSentBeforeHidingIsTakenWhenThePaneIsWaitingAgain() async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeHiddenMidRequestStore(client)

      await store.send(.controlRequested) {
        $0.wantsControl = true
        $0.requestID = UUID(1)
        $0.phase = .requesting
      }
      await store.send(.event(.message(.grant(request: UUID(0), lease: lease)))) {
        $0.requestID = nil
        $0.unansweredRequests = [UUID(1)]
        $0.lease = self.lease
        $0.phase = .controlling
      }
      await store.send(.event(.message(.denied(request: UUID(1), reason: "Control is already active.")))) {
        $0.unansweredRequests = []
      }

      #expect(store.state.message == nil)
      expectNoDifference(client.messages(to: endpoint), [.request(id: UUID(0)), .request(id: UUID(1))])
      expectNoDifference(client.beginInputs.map(\.lease), [lease])
      await store.send(.controlReleased(reason: nil)) {
        $0.wantsControl = false
        $0.lease = nil
        $0.phase = .viewing
      }
      await store.receive(\.delegate.released)
    }
  }

  @Test(arguments: [true, false])
  func anAnswerThatArrivesWhileHiddenSettlesTheRequestAndShowingAgainAsksAfresh(granted: Bool) async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = await makeHiddenMidRequestStore(client)
      let answer: ScreenSharingControlMessage =
        granted
        ? .grant(request: UUID(0), lease: lease) : .denied(request: UUID(0), reason: "Control is already active.")

      await store.send(.event(.message(answer))) { $0.unansweredRequests = [] }
      await store.send(.controlRequested) {
        $0.wantsControl = true
        $0.requestID = UUID(1)
        $0.phase = .requesting
      }

      let released: [ScreenSharingControlMessage] = granted ? [.release(lease: lease)] : []
      expectNoDifference(client.messages(to: endpoint), [.request(id: UUID(0))] + released + [.request(id: UUID(1))])
      #expect(store.state.message == nil, "a denial of a request nobody is waiting for is not shown")
      await store.send(.suspended) {
        $0.wantsControl = false
        $0.requestID = nil
        $0.unansweredRequests = [UUID(1)]
        $0.phase = .viewing
      }
    }
  }

  @Test(arguments: [false, true])
  func aGrantForARequestAnotherPaneSentIsLeftAlone(whileWaiting: Bool) async {
    await withMainSerialExecutor {
      let client = FakeEndpointClient()
      let store = makeStore(client)
      await store.send(.event(.availability(true))) { $0.available = true }
      if whileWaiting {
        await store.send(.controlRequested) {
          $0.wantsControl = true
          $0.requestID = UUID(0)
          $0.phase = .requesting
        }
      }

      await store.send(.event(.message(.grant(request: UUID(), lease: lease))))

      expectNoDifference(client.messages(to: endpoint), whileWaiting ? [.request(id: UUID(0))] : [])
      expectNoDifference(client.beginInputs.count, 0)
      await store.send(.event(.availability(false))) {
        $0.available = false
        $0.requestID = nil
        $0.phase = .viewing
      }
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

  private func makeHiddenMidRequestStore(
    _ client: FakeEndpointClient, clock: any Clock<Duration> = Clocks.TestClock()
  ) async -> TestStoreOf<ControlLease> {
    let store = makeStore(client, clock: clock)
    await store.send(.event(.availability(true))) { $0.available = true }
    await store.send(.controlRequested) {
      $0.wantsControl = true
      $0.requestID = UUID(0)
      $0.phase = .requesting
    }
    await store.send(.suspended) {
      $0.wantsControl = false
      $0.requestID = nil
      $0.unansweredRequests = [UUID(0)]
      $0.phase = .viewing
    }
    return store
  }

  private func makeRetryingStore(
    _ client: FakeEndpointClient, clock: Clocks.TestClock<Duration>
  ) async -> TestStoreOf<ControlLease> {
    let store = makeStore(client, clock: clock)
    await store.send(.event(.availability(true))) { $0.available = true }
    await store.send(.controlRequested) {
      $0.wantsControl = true
      $0.requestID = UUID(0)
      $0.phase = .requesting
    }
    await clock.advance(by: .seconds(3))
    await store.receive(\.requestTimedOut) {
      $0.requestID = UUID(1)
      $0.retriedRequest = true
      $0.unansweredRequests = [UUID(0)]
    }
    return store
  }
}
