import CryptoKit
import Foundation
import ScreenSharing

public struct RFBRecording: Decodable, Sendable {
  public struct Outcome: Decodable, Equatable, Sendable {
    public var updates: Int
    public var framebuffer: String
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

  public static func comparable(_ outcome: Outcome, lossy: Bool) -> Outcome {
    guard lossy else { return outcome }
    var copy = outcome
    copy.framebuffer = "lossy"
    return copy
  }

  public static func load(_ url: URL) throws -> RFBRecording {
    try JSONDecoder().decode(RFBRecording.self, from: Data(contentsOf: url))
  }

  public func replay() async throws -> Outcome {
    let transport = RFBReplayTransport(chunks: server.map { [UInt8]($0) })
    let client = try RFBClient(transport: transport, framebuffer: RFBFramebuffer(width: width, height: height))
    let log = ReplayLog()
    do {
      try await client.run(
        onUpdate: { _, update in log.update(update) },
        onEvent: { log.event($0) })
    } catch RFBError.connectionClosed {
    }
    return Outcome(updates: log.updates, framebuffer: Self.digest(client.framebuffer), events: log.events)
  }

  private static func digest(_ framebuffer: RFBFramebuffer) -> String {
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
        case .roundTrip: nil
        case .extendedClipboard(.caps(let formats, let actions, _)):
          "clipboard caps formats \(formats) actions \(String(actions >> 24, radix: 2))"
        default: "\(event)"
        }
      guard let text else { return }
      lock.withLock { events.append(text) }
    }
  }
}

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
