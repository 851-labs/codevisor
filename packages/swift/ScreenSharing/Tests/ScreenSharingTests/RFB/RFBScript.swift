import Foundation
import Testing
@testable import ScreenSharing

/// Server byte scripts assembled from the pieces the client reads in order, so
/// a test can truncate or vary exactly one field and leave the rest valid.
enum RFBScript {
  static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  static func serverInit(
    width: Int = 64, height: Int = 48, format: RFBPixelFormat = .bgra32, name: [UInt8] = Array("Loopback".utf8),
    declaredNameLength: UInt32? = nil
  ) -> [UInt8] {
    u16(UInt16(width)) + u16(UInt16(height)) + format.encoded + u32(declaredNameLength ?? UInt32(name.count)) + name
  }

  /// 3.8 offering only None, accepted: the shortest complete handshake.
  static func openHandshake(width: Int = 64, height: Int = 48, name: [UInt8] = Array("Loopback".utf8)) -> [UInt8] {
    bytes("RFB 003.008\n") + [1, 1] + u32(0) + serverInit(width: width, height: height, name: name)
  }

  /// A FramebufferUpdate carrying already-encoded rectangles.
  static func update(_ rectangles: [[UInt8]]) -> [UInt8] {
    [0, 0] + u16(UInt16(rectangles.count)) + rectangles.flatMap { $0 }
  }

  static func rectangle(_ rect: RFBRectangle, _ encoding: Int32, _ payload: [UInt8] = []) -> [UInt8] {
    u16(UInt16(truncatingIfNeeded: rect.x)) + u16(UInt16(truncatingIfNeeded: rect.y))
      + u16(UInt16(truncatingIfNeeded: rect.width)) + u16(UInt16(truncatingIfNeeded: rect.height)) + s32(encoding)
      + payload
  }

  /// `rect.width * rect.height` BGRA pixels of one colour, as Raw wants them.
  static func rawPixels(_ rect: RFBRectangle, blue: UInt8, green: UInt8, red: UInt8) -> [UInt8] {
    Array(repeatElement([blue, green, red, 0xff], count: rect.width * rect.height).joined())
  }
}

func s32(_ value: Int32) -> [UInt8] { u32(UInt32(bitPattern: value)) }

func performHandshake(
  _ transport: ScriptedTransport, password: String?, shared: Bool = true
) async throws -> RFBHandshake.Outcome {
  try await RFBHandshake.perform(
    stream: RFBInputStream(transport: transport), transport: transport, password: password, shared: shared)
}

/// The framebuffer as it stood when one update was reported; the read loop is
/// free to overwrite it as soon as the callback returns.
struct FrameSnapshot: Sendable {
  let update: RFBUpdate
  let width: Int
  let height: Int
  let pixels: [UInt8]
  func pixel(x: Int, y: Int) -> [UInt8] {
    let index = (y * width + x) * 4
    return Array(pixels[index..<index + 4])
  }
}

/// A client run to the end of a scripted byte stream. `run` can only stop by
/// throwing, and a script that runs out ends it with `connectionClosed`, so
/// every case settles with no waiting, no sockets and no scheduler luck.
struct ScriptedSession {
  let outcome: RFBHandshake.Outcome
  let updates: [FrameSnapshot]
  let events: [RFBServerEvent]
  let written: [UInt8]
  let error: any Error

  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var updates: [FrameSnapshot] = []
    private(set) var events: [RFBServerEvent] = []
    func record(_ framebuffer: RFBFramebuffer, _ update: RFBUpdate) {
      lock.withLock {
        updates.append(
          FrameSnapshot(
            update: update, width: framebuffer.width, height: framebuffer.height, pixels: framebuffer.pixels))
      }
    }
    func record(_ event: RFBServerEvent) { lock.withLock { events.append(event) } }
  }

  /// `chunk` deliberately does not divide any field, so no boundary in the
  /// script lines up with a read.
  static func play(
    _ serverMessages: [UInt8], handshake: [UInt8] = RFBScript.openHandshake(), password: String? = nil, chunk: Int = 7
  ) async throws -> ScriptedSession {
    let transport = ScriptedTransport(handshake + serverMessages, chunk: chunk)
    let client = try RFBClient(transport: transport)
    let outcome = try await client.connect(password: password)
    let recorder = Recorder()
    var failure: (any Error)?
    do {
      try await client.run(onUpdate: { recorder.record($0, $1) }, onEvent: { recorder.record($0) })
    } catch {
      failure = error
    }
    return ScriptedSession(
      outcome: outcome, updates: recorder.updates, events: recorder.events, written: transport.written,
      error: try #require(failure))
  }
}
