import Foundation
import Testing
@testable import CodevisorCore

@Suite("ReorderSettle")
struct ReorderSettleTests {
    @Test("A fresh hold waits the full quiet delay")
    func freshHoldUsesQuietDelay() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(ReorderSettle.delay(holdStart: start, now: start) == ReorderSettle.quietDelay)
    }

    @Test("Approaching the max hold shortens the wait")
    func nearMaxHoldShortensDelay() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let now = start.addingTimeInterval(ReorderSettle.maxHold - 0.1)
        #expect(abs(ReorderSettle.delay(holdStart: start, now: now) - 0.1) < 0.0001)
    }

    @Test("Past the max hold the wait is zero, never negative")
    func pastMaxHoldIsZero() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let now = start.addingTimeInterval(ReorderSettle.maxHold + 5)
        #expect(ReorderSettle.delay(holdStart: start, now: now) == 0)
    }
}
