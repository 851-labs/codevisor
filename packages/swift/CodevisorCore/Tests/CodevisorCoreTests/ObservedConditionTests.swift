import CodevisorTestSupport
import Observation
import Testing

@MainActor
@Suite("Observable test synchronization")
struct ObservedConditionTests {
  @Observable
  final class State {
    var ready = false
  }

  @Test("A change between the first read and observer registration cannot be lost")
  func changeDuringRegistration() async {
    let state = State()
    var reads = 0
    await awaitObserved {
      let ready = state.ready
      reads += 1
      if reads == 1 {
        state.ready = true
      }
      return ready
    }
    #expect(reads == 2)
    #expect(state.ready)
  }
}
