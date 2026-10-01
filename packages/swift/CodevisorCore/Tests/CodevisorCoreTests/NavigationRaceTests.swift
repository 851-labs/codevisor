import CodevisorClient
import CodevisorTestSupport
import ConcurrencyExtras
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct NavigationRaceTests {
  @Test("A forgotten machine cannot be restored by mapping already in flight")
  func forgetDuringMapping() async {
    await withMainSerialExecutor {
      let store = NavigationStore(store: InMemoryStore())
      let mapping = Task { await store.replace(.fixture(cursor: 10), machineId: "m", requestedAt: Date()) }
      let removal = Task { store.forget(machineId: "m") }
      await removal.value
      _ = await mapping.value
      #expect(!store.hasCache(for: "m"))
    }
  }

  @Test("An intervening refresh cannot acknowledge a newer delta without applying it")
  func refreshDuringDelta() async {
    await withMainSerialExecutor {
      let store = NavigationStore(store: InMemoryStore())
      await store.replace(.fixture(cursor: 10), machineId: "m", requestedAt: Date())
      let refresh = Task {
        await store.replace(.fixture(cursor: 20), machineId: "m", requestedAt: Date(), resetsStream: false)
      }
      let delta = Task { await store.apply(.fixture(cursor: 30), machineId: "m") }
      _ = await refresh.value
      #expect(await delta.value)
      #expect(store.eventCursor(for: "m") == 30)
    }
  }

  @Test("Forgetting a machine invalidates an outstanding refresh response")
  func forgetDuringFetch() async {
    let store = NavigationStore(store: InMemoryStore())
    let server = NavigationJournalServer(.fixture(cursor: 10))
    let entered = TestSignal()
    let release = TestSignal()
    server.onSnapshot {
      entered.signal(); await release.wait()
    }
    let refreshing = Task { await store.refresh(machineId: "m", client: server) }
    await entered.wait()
    store.forget(machineId: "m")
    release.signal()
    #expect(await refreshing.value == .superseded)
    #expect(!store.hasCache(for: "m"))
  }
}
