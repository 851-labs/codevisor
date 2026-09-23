import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// What each update costs on the wire and how long it took after its request
/// (851-2309): the numbers VNC diagnostics and `vnc-bench` are built from.
struct RFBUpdateMeasurementTests {
  /// Instants handed out in order; the last one repeats.
  final class ScriptedNow: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var offsets: [Duration]
    init(_ offsets: [Duration]) { self.offsets = offsets }
    func next() -> ContinuousClock.Instant {
      lock.withLock { base + (offsets.count > 1 ? offsets.removeFirst() : offsets[0]) }
    }
  }

  @Test func anUpdateCarriesItsWireBytesAndItsLatencySinceTheRequest() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    // Request sent at 0 ms, update applied at 42 ms, next request at 50 ms.
    let now = ScriptedNow([.zero, .milliseconds(42), .milliseconds(50)])
    let client = try RFBClient(
      transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port), now: now.next)
    _ = try await client.connect(password: "secret")
    let (updates, continuation) = AsyncStream<RFBUpdate>.makeStream()
    let run = Task { try await client.run(onUpdate: { _, update in continuation.yield(update) }, onEvent: { _ in }) }
    defer {
      run.cancel()
      client.close()
    }
    var iterator = updates.makeAsyncIterator()
    let first = try #require(await iterator.next())
    // Type, padding and count (4) + one rectangle header (12) + 64 × 48 raw BGRA pixels.
    #expect(first.byteCount == 4 + 12 + 64 * 48 * 4)
    #expect(first.latency == .milliseconds(42))
  }

  @Test func equalityIsAboutContentNotMeasurements() {
    var measured = RFBUpdate(rectangles: [], resized: true)
    measured.byteCount = 16
    measured.latency = .milliseconds(3)
    #expect(measured == RFBUpdate(rectangles: [], resized: true))
    #expect(RFBUpdate(rectangles: [], resized: false).latency == nil, "Unmeasured until the client sets it.")
  }

  @Test func theStreamCountsWhatItConsumed() async throws {
    let transport = ScriptedTransport([1, 2, 3, 4, 5, 6, 7, 8, 9])
    let stream = RFBInputStream(transport: transport)
    _ = try await stream.u8()
    _ = try await stream.u16()
    _ = try await stream.bytes(3)
    #expect(stream.consumed == 6)
  }

  @Test func transportsNameThemselves() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    let tcp = try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port)
    defer { tcp.close() }
    #expect(tcp.name == "TCP")
    #expect(RFBShapedTransport(tcp, profile: .wan150, clock: ContinuousClock()).name == "TCP · shaped wan150")
  }
}
