import Foundation
import Testing

@testable import ScreenSharing

struct ScreenSharingWireFormatTests {
  static let controlMessages: [ScreenSharingControlMessage] = {
    let lease = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!
    let request = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let events: [ScreenSharingInputEvent] = [
      .move(.init(x: 0, y: 1), modifiers: 0),
      .button(.init(x: 0.25, y: 0.75), button: 2, down: true, clicks: 3, modifiers: 63),
      .scroll(.init(x: 0.5, y: 0.5), x: -4096, y: 4096, modifiers: 1),
      .key(code: 126, down: false, repeatKey: true, modifiers: 8),
      .text("é👩🏽‍💻日本語\n\u{0B}"),
    ]
    return [
      .request(id: request),
      .grant(request: request, lease: lease),
      .denied(request: request, reason: "Someone else is in control."),
      .release(lease: lease),
      .revoked(lease: lease, reason: ""),
      .heartbeat(lease: lease),
    ]
      + events.enumerated().map { .input(lease: lease, sequence: UInt64($0.offset), event: $0.element) }
  }()

  static let clipboardMessages: [ScreenSharingClipboardMessage] = {
    let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!
    let payload = Data((0..<256).map { UInt8(($0 &* 37) & 0xFF) })
    return [
      .read(id: id),
      .begin(id: id, bytes: ScreenSharingClipboardMessage.maximumTextBytes),
      .begin(id: id, bytes: ScreenSharingClipboardMessage.maximumContentBytes, richContent: true),
      .chunk(id: id, index: 31, data: payload),
      .ack(id: id, nextIndex: 0),
      .end(id: id),
      .result(id: id, error: nil),
      .result(id: id, error: "Clipboard is unavailable or busy."),
      .cancel(id: id),
    ]
  }()

  @Test(arguments: ScreenSharingWireFormatTests.controlMessages)
  func everyControlMessageSurvivesItsEnvelopeUnchanged(_ message: ScreenSharingControlMessage) throws {
    let data = try message.encoded()
    let decoded = try ScreenSharingControlMessage.decode(data)
    #expect(decoded == message)
    #expect(try Self.tree(decoded.encoded()) == Self.tree(data))
    #expect(data.count <= ScreenSharingControlMessage.maximumBytes)
  }

  @Test(arguments: ScreenSharingWireFormatTests.clipboardMessages)
  func everyClipboardMessageSurvivesItsEnvelopeUnchanged(_ message: ScreenSharingClipboardMessage) throws {
    let data = try message.encoded()
    let decoded = try ScreenSharingClipboardMessage.decode(data)
    #expect(decoded == message)
    #expect(try Self.tree(decoded.encoded()) == Self.tree(data))
    #expect(decoded.id == message.id)
  }

  @Test func anUnknownFieldInsideAKnownCaseIsIgnored() throws {
    let message = ScreenSharingControlMessage.heartbeat(lease: UUID())
    let extended = try Self.rewrite(message.encoded()) { envelope in
      guard let payload = envelope["message"] as? [String: Any], let name = payload.keys.first,
        var body = payload[name] as? [String: Any]
      else { return }
      body["expiresAt"] = 123
      envelope["message"] = [name: body]
    }
    #expect(try ScreenSharingControlMessage.decode(extended) == message)
  }

  @Test func anUnknownCaseIsRejectedRatherThanMisread() throws {
    let control = try Self.rewrite(ScreenSharingControlMessage.heartbeat(lease: UUID()).encoded()) {
      $0["message"] = ["teleport": ["lease": UUID().uuidString]]
    }
    #expect(throws: DecodingError.self) { try ScreenSharingControlMessage.decode(control) }
    let clipboard = try Self.rewrite(ScreenSharingClipboardMessage.end(id: UUID()).encoded()) {
      $0["message"] = ["compress": ["id": UUID().uuidString]]
    }
    #expect(throws: DecodingError.self) { try ScreenSharingClipboardMessage.decode(clipboard) }
  }

  @Test func anEnvelopeFromAnotherProtocolVersionIsRefused() throws {
    let clipboard = try Self.rewrite(ScreenSharingClipboardMessage.read(id: UUID()).encoded()) { $0["version"] = 2 }
    expectInvalid("Unsupported clipboard protocol.") { try ScreenSharingClipboardMessage.decode(clipboard) }
    for version in [0, 2] {
      let control = try Self.rewrite(ScreenSharingControlMessage.release(lease: UUID()).encoded()) {
        $0["version"] = version
      }
      expectInvalid("Unsupported control protocol.") { try ScreenSharingControlMessage.decode(control) }
    }
  }

  @Test func aMessageLargerThanTheChannelIsRefusedByBothEnds() throws {
    let text = String(repeating: "\u{0B}", count: 1024)
    #expect(ScreenSharingInputEvent.text(text).isValid)
    let oversize = ScreenSharingControlMessage.input(lease: UUID(), sequence: 0, event: .text(text))
    expectInvalid("Control message is too large.") { try oversize.encoded() }
    expectInvalid("Control message is too large.") {
      try ScreenSharingControlMessage.decode(Data(repeating: 0x20, count: 4097))
    }

    let chunk = ScreenSharingClipboardMessage.chunk(
      id: UUID(), index: 0, data: Data(repeating: 255, count: ScreenSharingClipboardMessage.maximumBytes))
    expectInvalid("Clipboard message is too large.") { try chunk.encoded() }
    expectInvalid("Clipboard message is too large.") {
      try ScreenSharingClipboardMessage.decode(
        Data(repeating: 0x20, count: ScreenSharingClipboardMessage.maximumBytes + 1))
    }
  }

  @Test func plainTextMessagesKeepTheShapeHostsThatPredateRichContentDecode() throws {
    let begin = try Self.tree(ScreenSharingClipboardMessage.begin(id: UUID(), bytes: 5).encoded())
    let body = try #require((begin["message"] as? [String: Any])?["begin"] as? [String: Any])
    #expect(Set(body.keys) == ["id", "bytes"])
    let viewer = try Self.tree(ScreenSharingClipboardSharingMessage.viewer(sharing: true).encoded())
    let sharing = try #require((viewer["message"] as? [String: Any])?["viewer"] as? [String: Any])
    #expect(Set(sharing.keys) == ["sharing"])
  }

  @Test func clipboardSharingMessagesSurviveTheirEnvelope() throws {
    for message: ScreenSharingClipboardSharingMessage in [
      .viewer(sharing: false), .viewer(sharing: true, richContent: true), .host(richContent: true),
    ] {
      #expect(try ScreenSharingClipboardSharingMessage.decode(message.encoded()) == message)
    }
  }

  @Test func aTruncatedChunkNeverDecodesIntoAShorterOne() throws {
    let payload = Data(repeating: 0xAB, count: ScreenSharingClipboardMessage.chunkBytes)
    let data = try ScreenSharingClipboardMessage.chunk(id: UUID(), index: 4, data: payload).encoded()
    for keep in [data.count - 1, data.count / 2, 1] {
      #expect(throws: DecodingError.self) { try ScreenSharingClipboardMessage.decode(data.prefix(keep)) }
    }
    let clipped = try Self.rewrite(data) { envelope in
      guard var body = (envelope["message"] as? [String: Any])?["chunk"] as? [String: Any],
        let base64 = body["data"] as? String
      else { return }
      body["data"] = String(base64.dropLast(3))
      envelope["message"] = ["chunk": body]
    }
    #expect(throws: DecodingError.self) { try ScreenSharingClipboardMessage.decode(clipped) }
    #expect(throws: (any Error).self) { try ScreenSharingClipboardMessage.decode(Data()) }
  }

  @Test(arguments: [
    ScreenSharingInputEvent.move(.init(x: 1.5, y: 0), modifiers: 0),
    .move(.init(x: 0, y: 0), modifiers: 64),
    .button(.init(x: 0, y: 0), button: 3, down: true, clicks: 1, modifiers: 0),
    .button(.init(x: 0, y: 0), button: 0, down: true, clicks: 0, modifiers: 0),
    .scroll(.init(x: 0, y: 0), x: 4097, y: 0, modifiers: 0),
    .scroll(.init(x: 0, y: 0), x: .min, y: 0, modifiers: 0),
    .key(code: 127, down: true, repeatKey: false, modifiers: 0),
    .text(""),
    .text(String(repeating: "x", count: 1025)),
  ])
  func anInputEventOutsideItsRangeIsRefusedOnDecode(_ event: ScreenSharingInputEvent) throws {
    #expect(!event.isValid)
    let message = ScreenSharingControlMessage.input(lease: UUID(), sequence: 7, event: event)
    expectInvalid("Invalid control input.") { try ScreenSharingControlMessage.decode(message.encoded()) }
    let lease = UUID()
    #expect(
      try ScreenSharingControlMessage.decode(ScreenSharingControlMessage.release(lease: lease).encoded())
        == .release(lease: lease))
  }

  private static func tree(_ data: Data) throws -> NSDictionary {
    try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }

  private static func rewrite(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    change(&object)
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func expectInvalid(
    _ message: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> some Any
  ) {
    do {
      _ = try body()
      Issue.record("expected \(message), nothing was thrown", sourceLocation: sourceLocation)
    } catch ScreenSharingError.invalid(let reason) {
      #expect(reason == message, sourceLocation: sourceLocation)
    } catch {
      Issue.record("expected \(message), got \(error)", sourceLocation: sourceLocation)
    }
  }
}
