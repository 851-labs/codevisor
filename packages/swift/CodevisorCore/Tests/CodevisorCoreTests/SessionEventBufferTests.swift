import Testing
@testable import CodevisorCore

struct SessionEventBufferTests {
  @Test func overflowRequiresFreshSnapshotAndRejectsCancelledConsumer() {
    let buffer = SessionEventBuffer()
    let old = buffer.beginConsumer()
    for cursor in 1...512 {
      buffer.append(.synchronization(.caughtUp), cursor: cursor, generation: old, byteCount: 1)
    }
    #expect(!buffer.overflowed)
    buffer.append(.synchronization(.caughtUp), cursor: 513, generation: old, byteCount: 1)
    #expect(buffer.overflowed)
    #expect(buffer.takeAll().isEmpty)
    #expect(!buffer.append(.synchronization(.caughtUp), generation: old))

    let fresh = buffer.beginConsumer()
    #expect(!buffer.overflowed)
    #expect(!buffer.append(.synchronization(.caughtUp), cursor: 514, generation: old))
    #expect(buffer.append(.synchronization(.caughtUp), cursor: 600, generation: fresh))
    #expect(buffer.takeAll().map(\.cursor) == [600])
  }

  @Test func oversizedEventDoesNotBecomeResident() {
    let buffer = SessionEventBuffer()
    let generation = buffer.beginConsumer()
    #expect(!buffer.append(.synchronization(.caughtUp), generation: generation, byteCount: 512 * 1024 + 1))
    #expect(buffer.overflowed)
    #expect(buffer.isEmpty)
  }
}
