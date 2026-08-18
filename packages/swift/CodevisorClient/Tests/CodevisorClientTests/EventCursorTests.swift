import Foundation
import Testing

@testable import CodevisorClient

@Suite("Event stream cursor")
struct EventCursorTests {
    @Test("Live-only sentinel cursors adopt the first real event id")
    func sentinelAdoptsFirstEvent() {
        // The transport-level sentinel (JS Number.MAX_SAFE_INTEGER) and
        // anything above it are live-only placeholders, not positions:
        // the first real event id must replace them so reconnects replay
        // missed events instead of resubscribing live-only forever.
        #expect(
            CodevisorServerClient.advanceEventCursor(
                ServerSessionTransport.liveOnlyEventCursor,
                to: 42
            ) == 42
        )
        #expect(CodevisorServerClient.advanceEventCursor(Int.max, to: 42) == 42)
    }

    @Test("Real cursors advance monotonically")
    func realCursorAdvances() {
        #expect(CodevisorServerClient.advanceEventCursor(0, to: 7) == 7)
        #expect(CodevisorServerClient.advanceEventCursor(7, to: 12) == 12)
        // Out-of-order ids never move the cursor backwards.
        #expect(CodevisorServerClient.advanceEventCursor(9, to: 7) == 9)
    }
}
