public final class TrackedStream<Element: Sendable>: @unchecked Sendable {
  private var iterator: AsyncThrowingStream<Element, any Error>.Iterator
  public let reads: TestSignal

  public init(_ source: AsyncThrowingStream<Element, any Error>, reads: TestSignal) {
    iterator = source.makeAsyncIterator()
    self.reads = reads
  }

  public var stream: AsyncThrowingStream<Element, any Error> {
    AsyncThrowingStream(unfolding: {
      self.reads.signal()
      return try await self.iterator.next()
    })
  }
}
