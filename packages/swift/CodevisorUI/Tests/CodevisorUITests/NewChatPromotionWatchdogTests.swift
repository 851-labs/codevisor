import CodevisorTestSupport
import Testing

@testable import CodevisorUI

@MainActor
@Suite("New Chat handoff deadline")
struct NewChatPromotionWatchdogTests {
  @Test("Missing UI callbacks complete through the fallback at the deadline")
  func missingCallbacks() async {
    let clock = TestClock()
    let watchdog = NewChatPromotionWatchdog(sleep: { try await clock.sleep(for: $0) })
    let fired = TestSignal()
    watchdog.start { fired.signal() }
    await clock.waitForSleep(NewChatPromotionWatchdog.timeout)
    clock.advance(by: NewChatPromotionWatchdog.timeout - .milliseconds(1))
    #expect(fired.value == 0)
    clock.advance(by: .milliseconds(1))
    await fired.wait()
    #expect(fired.value == 1)
    watchdog.cancel()
  }

  @Test("A successful handoff cancels its fallback")
  func successfulHandoff() async {
    let clock = TestClock()
    let finishedSleeping = TestSignal()
    let fired = TestSignal()
    let observedWatchdog = NewChatPromotionWatchdog(sleep: {
      defer { finishedSleeping.signal() }
      try await clock.sleep(for: $0)
    })
    observedWatchdog.start { fired.signal() }
    await clock.waitForSleep(NewChatPromotionWatchdog.timeout)
    observedWatchdog.cancel()
    await finishedSleeping.wait()
    clock.advance(by: NewChatPromotionWatchdog.timeout)
    #expect(fired.value == 0)
    #expect(clock.pendingCount == 0)
  }
}
