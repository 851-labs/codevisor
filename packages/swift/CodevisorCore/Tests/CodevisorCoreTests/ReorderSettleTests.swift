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

    @Test("A foreground hold keeps quiet-delay pacing under its larger budget")
    func foregroundBudgetExtendsHold() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        // A fresh foreground hold waits its own (longer) quiet delay, so the
        // pre-emptive lock survives recovery latency before the burst.
        #expect(
            ReorderSettle.delay(
                holdStart: start,
                now: start,
                quietDelay: ReorderSettle.foregroundQuietDelay,
                maxHold: ReorderSettle.foregroundMaxHold
            ) == ReorderSettle.foregroundQuietDelay
        )
        // Past the reactive budget but well inside the foreground one: the
        // hold keeps waiting a full quiet delay instead of releasing.
        let now = start.addingTimeInterval(ReorderSettle.maxHold + 1)
        #expect(
            ReorderSettle.delay(
                holdStart: start,
                now: now,
                quietDelay: ReorderSettle.foregroundQuietDelay,
                maxHold: ReorderSettle.foregroundMaxHold
            ) == ReorderSettle.foregroundQuietDelay
        )
        // And the foreground budget still bounds it.
        let nearEnd = start.addingTimeInterval(ReorderSettle.foregroundMaxHold + 1)
        #expect(
            ReorderSettle.delay(
                holdStart: start,
                now: nearEnd,
                quietDelay: ReorderSettle.foregroundQuietDelay,
                maxHold: ReorderSettle.foregroundMaxHold
            ) == 0
        )
    }
}
