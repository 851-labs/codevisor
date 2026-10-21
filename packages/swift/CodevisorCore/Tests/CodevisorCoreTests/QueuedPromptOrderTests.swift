import Testing

@testable import CodevisorCore

@Suite("Dragging a queued message onto another")
struct QueuedPromptOrderTests {
  @Test(
    "Takes the target's place, in either direction",
    arguments: [
      ("c", "a", ["c", "a", "b"]),
      ("a", "c", ["b", "c", "a"]),
      ("a", "b", ["b", "a", "c"]),
      ("a", "a", ["a", "b", "c"]),
      ("missing", "a", ["a", "b", "c"]),
    ]
  )
  func moving(dragged: String, target: String, expected: [String]) {
    #expect(QueuedPromptOrder.moving(dragged, onto: target, in: ["a", "b", "c"]) == expected)
  }
}
