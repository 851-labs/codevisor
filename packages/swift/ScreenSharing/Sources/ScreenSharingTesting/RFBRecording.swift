import CryptoKit
import Foundation
import ScreenSharing

/// A real server's bytes, captured after the handshake, that replay into the
/// client with no server (docs/plans/vnc-validation.md: real-server behaviour
/// becomes L1 fixtures). Recordings never hold credentials: capture starts
/// once authentication is over.
///
/// Format (JSON): `version`, `source` (free text naming the server), the
/// framebuffer `width` × `height` after the handshake, `server` (the bytes
/// the client read, base64, in read-sized chunks) and `expected` — what
/// replaying those bytes produced when the recording was made. The replay
/// test re-derives `expected` and must match it exactly.
public struct RFBRecording: Codable, Equatable, Sendable {
  public struct Outcome: Codable, Equatable, Sendable {
    /// Framebuffer updates applied.
    public var updates: Int
    /// SHA-256 of the final framebuffer's colour bytes (B, G, R; padding excluded), hex;
    /// `lossy` for a recording with JPEG, whose decoded pixels may differ across OS versions.
    public var framebuffer: String
    /// Every update's pseudo-rectangles and every server event, in order, as text.
    public var events: [String]

    public init(updates: Int, framebuffer: String, events: [String]) {
      self.updates = updates
      self.framebuffer = framebuffer
      self.events = events
    }
  }

  public var version = 1
  public var source: String
  public var width: Int
  public var height: Int
  public var server: [Data]
  public var expected: Outcome?

  public init(source: String, width: Int, height: Int, server: [Data], expected: Outcome? = nil) {
    self.source = source
    self.width = width
    self.height = height
    self.server = server
    self.expected = expected
  }

  public var byteCount: Int { server.reduce(0) { $0 + $1.count } }

  /// A replay outcome as recorded: lossy recordings keep everything but the pixel hash.
  public static func comparable(_ outcome: Outcome, lossy: Bool) -> Outcome {
    guard lossy else { return outcome }
    var copy = outcome
    copy.framebuffer = "lossy"
    return copy
  }

  public static func load(_ url: URL) throws -> RFBRecording {
    try JSONDecoder().decode(RFBRecording.self, from: Data(contentsOf: url))
  }

  public func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url)
  }

  /// Feeds the recorded bytes to a fresh client sized like the recording and
  /// runs it until the bytes run out. Deterministic: it depends on the bytes only.
  public func replay() async throws -> Outcome {
    let transport = RFBReplayTransport(chunks: server.map { [UInt8]($0) })
    let client = try RFBClient(transport: transport, framebuffer: RFBFramebuffer(width: width, height: height))
    let log = ReplayLog()
    do {
      try await client.run(
        onUpdate: { _, update in log.update(update) },
        onEvent: { log.event($0) })
    } catch RFBError.connectionClosed {
      // The recording ended; a trailing partial message is expected.
    }
    return Outcome(updates: log.updates, framebuffer: Self.digest(client.framebuffer), events: log.events)
  }

  public static func digest(_ framebuffer: RFBFramebuffer) -> String {
    var hash = SHA256()
    framebuffer.withPixels { pixels, _ in
      var colour = [UInt8]()
      colour.reserveCapacity(pixels.count / 4 * 3)
      for index in stride(from: 0, to: pixels.count, by: 4) {
        colour.append(pixels[index]); colour.append(pixels[index + 1]); colour.append(pixels[index + 2])
      }
      hash.update(data: colour)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private final class ReplayLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var updates = 0
    private(set) var events: [String] = []
    func update(_ update: RFBUpdate) {
      lock.withLock {
        updates += 1
        if update.resized { events.append("resized") }
        if let cursor = update.cursor {
          events.append("cursor \(cursor.width)x\(cursor.height) hotspot \(cursor.hotspotX),\(cursor.hotspotY)")
        }
        if let pointer = update.pointer { events.append("pointer \(pointer.x),\(pointer.y)") }
        if update.jpegRectangles > 0 { events.append("jpeg \(update.jpegRectangles)") }
        if let size = update.desktopSize {
          events.append(
            "desktop \(size.width)x\(size.height) \(size.reason) \(size.status) screens \(size.screens.count)")
        }
      }
    }
    func event(_ event: RFBServerEvent) {
      let text: String? =
        switch event {
        case .roundTrip: nil  // timing, not content
        case .extendedClipboard(.caps(let formats, let actions, _)):
          "clipboard caps formats \(formats) actions \(String(actions >> 24, radix: 2))"
        default: "\(event)"
        }
      guard let text else { return }
      lock.withLock { events.append(text) }
    }
  }
}

/// Wraps a live transport and records what the client reads once `start()`
/// is called (after the handshake, so no authentication bytes are kept).
public final class RFBRecordingTransport: RFBTransport, @unchecked Sendable {
  private let inner: any RFBTransport
  private let lock = NSLock()
  private var recording = false
  private var chunks: [Data] = []

  public init(_ inner: any RFBTransport) { self.inner = inner }

  public var name: String { inner.name }
  public var recorded: [Data] { lock.withLock { chunks } }

  public func start() { lock.withLock { recording = true } }
  public func stop() { lock.withLock { recording = false } }

  public func read(maximum: Int) async throws -> [UInt8] {
    let bytes = try await inner.read(maximum: maximum)
    lock.withLock { if recording, !bytes.isEmpty { chunks.append(Data(bytes)) } }
    return bytes
  }

  public func write(_ bytes: [UInt8]) async throws { try await inner.write(bytes) }
  public func close() { inner.close() }
}

/// Serves recorded chunks in order, then end of stream; accepts and discards writes.
final class RFBReplayTransport: RFBTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var chunks: [[UInt8]]
  private var buffered: [UInt8] = []

  init(chunks: [[UInt8]]) { self.chunks = chunks }

  var name: String { "Replay" }

  func read(maximum: Int) async throws -> [UInt8] {
    lock.withLock {
      if buffered.isEmpty, !chunks.isEmpty { buffered = chunks.removeFirst() }
      let count = min(max(1, maximum), buffered.count)
      defer { buffered.removeFirst(count) }
      return Array(buffered.prefix(count))
    }
  }

  func write(_ bytes: [UInt8]) async throws {}
  func close() {}
}
