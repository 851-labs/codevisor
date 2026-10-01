import Foundation
import Testing

@testable import CodevisorCore

struct PersistenceConcurrencyTests {
  private func concurrentWrites(count: Int, _ write: @escaping @Sendable (Int) -> Void) {
    let ready = DispatchGroup()
    let finished = DispatchGroup()
    let start = DispatchSemaphore(value: 0)
    for index in 0..<count {
      ready.enter()
      finished.enter()
      Thread.detachNewThread {
        ready.leave()
        start.wait()
        write(index)
        finished.leave()
      }
    }
    ready.wait()
    for _ in 0..<count { start.signal() }
    finished.wait()
  }

  private func ids() -> [UUID] {
    (1...64).map { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))! }
  }

  @Test("Concurrent pane saves preserve every session across repository reload")
  func paneSaves() {
    let store = InMemoryStore()
    let repository = DefaultPaneGroupRepository(store: store)
    let ids = ids()
    let states = ids.map { id in
      var state = PaneGroupState()
      state.addTerminalPane(sessionId: id)
      return state
    }
    concurrentWrites(count: ids.count) { index in
      repository.save(states[index], sessionId: ids[index])
    }
    let reloaded = DefaultPaneGroupRepository(store: store)
    for (index, id) in ids.enumerated() { #expect(reloaded.load(sessionId: id) == states[index]) }
  }

}
