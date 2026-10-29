import CodevisorTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CancelledWaitTests {
  @Test func aCancellableWaitForASignalThatNeverFiresEndsOnceCancelled() async {
    let signal = TestSignal(), entered = TestSignal()
    let waiting = Task {
      entered.signal()
      await signal.cancellableWait()
      return Task.isCancelled
    }
    await entered.wait()
    waiting.cancel()
    #expect(await waiting.value)
  }

  @Test func aSleepThatIsNeverRequestedStopsWaitingOnceCancelled() async {
    let clock = TestClock()
    let waiting = Task {
      await clock.waitForSleep(.seconds(1))
      return Task.isCancelled
    }
    waiting.cancel()
    #expect(await waiting.value)
  }

  @Test @MainActor func aConditionThatNeverHoldsStopsWaitingOnceCancelled() async {
    let waiting = Task { @MainActor in
      await awaitObserved { false }
      return Task.isCancelled
    }
    waiting.cancel()
    #expect(await waiting.value)
  }
}
