import Foundation

/// Big-endian message assembly.
public struct RFBByteWriter: Sendable {
  public private(set) var bytes: [UInt8] = []
  public init() {}
  public mutating func u8(_ value: UInt8) { bytes.append(value) }
  public mutating func u16(_ value: UInt16) { bytes.append(UInt8(value >> 8)); bytes.append(UInt8(value & 0xff)) }
  public mutating func u32(_ value: UInt32) {
    for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((value >> UInt32(shift)) & 0xff)) }
  }
  public mutating func s32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
  public mutating func pad(_ count: Int) { bytes.append(contentsOf: repeatElement(0, count: count)) }
  public mutating func append(_ more: [UInt8]) { bytes.append(contentsOf: more) }
}

/// Buffered big-endian reads over a transport. Owned by exactly one read
/// loop, which is why it is unchecked: two concurrent readers would
/// interleave bytes. The transport's chunking never shows through, which is
/// what the fixture tests rely on.
public final class RFBInputStream: @unchecked Sendable {
  private let transport: any RFBTransport
  private var buffer: [UInt8] = []
  private var offset = 0
  private let chunk: Int
  /// Bytes handed out so far, for per-message wire sizes.
  public private(set) var consumed = 0
  /// Bytes moved by compaction: at most one move per byte on average (851-2320).
  private(set) var bytesMoved = 0
  /// Link timing (851-2331): while on, bytes from reads that had to wait for
  /// the network and the time spent waiting. Data already buffered locally
  /// (kernel, a WebSocket message that arrived whole) adds neither, so it
  /// can't make the link look faster than it is.
  private var timing = false
  private var timedBytes = 0
  private var timedWait: Duration = .zero
  private let now: @Sendable () -> ContinuousClock.Instant
  /// A read that returned faster than this found its data already there.
  static let blockedThreshold: Duration = .milliseconds(1)

  public init(
    transport: any RFBTransport, chunk: Int = 1 << 16,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.transport = transport
    self.chunk = chunk
    self.now = now
  }

  /// Starts counting the link's arrivals (after an update's header: the wait
  /// for the header includes the idle time before the update).
  public func startTiming() {
    timing = true
    timedBytes = 0
    timedWait = .zero
  }

  /// Stops counting: the bytes that arrived while the reader waited, and how long it waited.
  public func stopTiming() -> (bytes: Int, duration: Duration) {
    timing = false
    return (timedBytes, timedWait)
  }

  public func u8() async throws -> UInt8 {
    try await fill(1)
    defer { advance(1) }
    return buffer[offset]
  }

  public func u16() async throws -> UInt16 {
    try await fill(2)
    defer { advance(2) }
    return UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1])
  }

  public func u32() async throws -> UInt32 {
    try await fill(4)
    defer { advance(4) }
    return UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16 | UInt32(buffer[offset + 2]) << 8
      | UInt32(buffer[offset + 3])
  }

  public func s32() async throws -> Int32 { Int32(bitPattern: try await u32()) }

  public func bytes(_ count: Int) async throws -> [UInt8] {
    guard count >= 0 else { throw RFBError.malformed("negative length") }
    try await fill(count)
    defer { advance(count) }
    return Array(buffer[offset..<offset + count])
  }

  public func skip(_ count: Int) async throws { _ = try await bytes(count) }

  private func advance(_ count: Int) {
    offset += count
    consumed += count
  }

  private func fill(_ count: Int) async throws {
    while buffer.count - offset < count {
      if offset > 0, offset >= buffer.count / 2 {
        bytesMoved += buffer.count - offset
        buffer.removeFirst(offset)
        offset = 0
      }
      let missing = count - (buffer.count - offset)
      let before = timing ? now() : nil
      let more = try await transport.read(maximum: max(chunk, missing))
      if more.isEmpty { throw RFBError.connectionClosed }
      if let before {
        let waited = before.duration(to: now())
        if waited >= Self.blockedThreshold {
          timedBytes += more.count
          timedWait += waited
        }
      }
      buffer.append(contentsOf: more)
    }
  }
}
