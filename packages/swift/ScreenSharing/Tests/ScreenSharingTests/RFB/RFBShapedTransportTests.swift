import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// Network shaping for L2 tests and `vnc-bench` (docs/plans/vnc-validation.md):
/// the delivery schedule is pure and exact; the transport applies it on an
/// injected clock.
struct RFBShapedTransportTests {
  // MARK: Schedule

  @Test func deliveryIsHalfTheRoundTripAfterSending() {
    var link = RFBLinkSchedule(profile: .init(name: "t", roundTrip: .milliseconds(150)))
    #expect(link.schedule(byteCount: 100, sentAt: .zero) == .milliseconds(75))
    #expect(link.schedule(byteCount: 100, sentAt: .milliseconds(10)) == .milliseconds(85))
  }

  @Test func bandwidthQueuesBackToBackSends() {
    // 10 Mbit/s: 12 500 bytes take 10 ms on the wire.
    var link = RFBLinkSchedule(profile: .init(name: "t", roundTrip: .zero, bitsPerSecond: 10_000_000))
    #expect(link.schedule(byteCount: 12_500, sentAt: .zero) == .milliseconds(10))
    #expect(link.schedule(byteCount: 12_500, sentAt: .zero) == .milliseconds(20), "The second waits for the first.")
    #expect(link.schedule(byteCount: 12_500, sentAt: .milliseconds(100)) == .milliseconds(110), "An idle link is free.")
  }

  @Test func jitterIsSeededAndNeverReorders() {
    let profile = RFBNetworkProfile(name: "t", roundTrip: .milliseconds(40), jitter: .milliseconds(15))
    func deliveries(seed: UInt64) -> [Duration] {
      var link = RFBLinkSchedule(profile: profile, seed: seed)
      return (0..<200).map { link.schedule(byteCount: 10, sentAt: .milliseconds($0)) }
    }
    let first = deliveries(seed: 1)
    #expect(first == deliveries(seed: 1))
    #expect(first != deliveries(seed: 2))
    #expect(zip(first, first.dropFirst()).allSatisfy { $0 <= $1 }, "Bytes arrive in the order they were sent.")
    #expect(Set(first.enumerated().map { $0.element - .milliseconds($0.offset) }).count > 1, "Jitter varies.")
  }

  @Test func namedProfiles() {
    #expect(RFBNetworkProfile.named("wan150")?.roundTrip == .milliseconds(150))
    #expect(RFBNetworkProfile.named("constrained")?.bitsPerSecond == 10_000_000)
    #expect(RFBNetworkProfile.named("nope") == nil)
    #expect(RFBNetworkProfile.all.map(\.name) == ["lan", "wan40", "wan150", "constrained"])
  }

  // MARK: Transport

  @Test func readsArriveAfterTheOneWayDelay() async throws {
    let clock = TestClock()
    let inner = PipeTransport()
    let shaped = RFBShapedTransport(inner, profile: .init(name: "t", roundTrip: .milliseconds(150)), clock: clock)
    defer { shaped.close() }
    inner.deliver([1, 2, 3])
    let read = Task { try await shaped.read(maximum: 16) }
    await clock.waitForSleep(.milliseconds(75))
    clock.advance(by: .milliseconds(74))
    #expect(clock.pendingCount == 1, "Still in flight 1 ms before it's due.")
    clock.advance(by: .milliseconds(1))
    #expect(try await read.value == [1, 2, 3])
  }

  @Test func writesReachThePeerAfterTheOneWayDelay() async throws {
    let clock = TestClock()
    let inner = PipeTransport()
    let shaped = RFBShapedTransport(inner, profile: .init(name: "t", roundTrip: .milliseconds(40)), clock: clock)
    defer { shaped.close() }
    try await shaped.write([9, 8])
    await clock.waitForSleep(.milliseconds(20))
    #expect(inner.written.isEmpty)
    clock.advance(by: .milliseconds(20))
    #expect(await awaitPolled { inner.written == [[9, 8]] })
  }

  @Test func thePeersCloseArrivesInOrderAfterItsData() async throws {
    let clock = TestClock()
    let inner = PipeTransport()
    let shaped = RFBShapedTransport(inner, profile: .init(name: "t", roundTrip: .zero), clock: clock)
    defer { shaped.close() }
    inner.deliver([7])
    inner.finish()
    #expect(try await shaped.read(maximum: 16) == [7])
    #expect(try await shaped.read(maximum: 16) == [], "End of stream after the data.")
  }

  @Test func closeFailsPendingReads() async throws {
    let clock = TestClock()
    let shaped = RFBShapedTransport(PipeTransport(), profile: .named("lan")!, clock: clock)
    let read = Task { try await shaped.read(maximum: 16) }
    await awaitReadWaiting(shaped)
    shaped.close()
    await #expect(throws: RFBError.self) { try await read.value }
  }

  /// Wiring: a real client through a shaped link to the reference server
  /// still converges on a scene. Real time on the `lan` profile; no timing
  /// is asserted.
  @Test func aClientWorksThroughAShapedLink() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.encoding = .zrle
    let server = try await RFBLoopbackServer(configuration: configuration)
    defer { server.stop() }
    let shaped = RFBShapedTransport(
      try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port), profile: .lan,
      clock: ContinuousClock())
    let client = try RFBClient(transport: shaped)
    _ = try await client.connect(password: "secret")
    let (updates, continuation) = AsyncStream<[UInt8]>.makeStream()
    let run = Task {
      try await client.run(onUpdate: { framebuffer, _ in continuation.yield(framebuffer.pixels) }, onEvent: { _ in })
    }
    defer {
      run.cancel()
      client.close()
    }
    var iterator = updates.makeAsyncIterator()
    _ = await iterator.next()
    var scene = RFBLoopbackScene(kind: .typing, seed: 5)
    for _ in 0..<4 {
      #expect(try server.play(&scene))
      let pixels = try #require(await iterator.next())
      #expect(colour(pixels) == colour(server.framebuffer.pixels))
    }
  }

  private func colour(_ pixels: [UInt8]) -> [UInt8] {
    pixels.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
  }

  /// A read registers before `close`, or the test only proves close-then-read.
  private func awaitReadWaiting(_ shaped: RFBShapedTransport<TestClock>) async {
    _ = await awaitPolled { shaped.waitingReads > 0 }
  }
}

/// An in-memory transport the test feeds and inspects.
final class PipeTransport: RFBTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var inbox: [[UInt8]] = []
  private var finished = false
  private var waiters: [CheckedContinuation<[UInt8], any Error>] = []
  private var writes: [[UInt8]] = []
  private var closed = false

  var written: [[UInt8]] { lock.withLock { writes } }

  func deliver(_ bytes: [UInt8]) {
    let waiter = lock.withLock { () -> CheckedContinuation<[UInt8], any Error>? in
      if waiters.isEmpty { inbox.append(bytes); return nil }
      return waiters.removeFirst()
    }
    waiter?.resume(returning: bytes)
  }

  func finish() {
    let pending = lock.withLock { () -> [CheckedContinuation<[UInt8], any Error>] in
      finished = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in pending { waiter.resume(returning: []) }
  }

  func read(maximum: Int) async throws -> [UInt8] {
    try await withCheckedThrowingContinuation { continuation in
      let result = lock.withLock { () -> Result<[UInt8], any Error>? in
        if closed { return .failure(RFBError.connectionClosed) }
        if !inbox.isEmpty { return .success(inbox.removeFirst()) }
        if finished { return .success([]) }
        waiters.append(continuation)
        return nil
      }
      if let result { continuation.resume(with: result) }
    }
  }

  func write(_ bytes: [UInt8]) async throws { lock.withLock { writes.append(bytes) } }

  func close() {
    let pending = lock.withLock { () -> [CheckedContinuation<[UInt8], any Error>] in
      closed = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in pending { waiter.resume(throwing: RFBError.connectionClosed) }
  }
}
