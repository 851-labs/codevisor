import Foundation
import Testing

@testable import CodevisorClient

@Suite("Event stream cursor")
struct EventCursorTests {
  @Test("Live-only sentinel cursors adopt the first real event id")
  func sentinelAdoptsFirstEvent() {
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
    #expect(CodevisorServerClient.advanceEventCursor(9, to: 7) == 9)
  }
}
