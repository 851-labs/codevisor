import CodevisorTestSupport
import Foundation
import Observation
import Testing
@testable import ScreenSharing

@MainActor
struct VNCClipboardRelayTests {
  final class FakeChannel: RFBControlChannel, @unchecked Sendable {
    var onControlText: (@Sendable (String) -> Void)?
    let (sends, continuation) = AsyncStream<String>.makeStream()
    func sendControlText(_ text: String) async throws { continuation.yield(text) }
  }

  @MainActor
  @Observable
  final class Viewer {
    private(set) var received: [ScreenSharingClipboardMessage] = []
    private(set) var richClipboard = false
    init(_ emulator: VNCHostEmulator) {
      emulator.clipboardChannel.onMessage = { [weak self] in self?.received.append($0) }
      emulator.onRichClipboardSupported = { [weak self] in self?.richClipboard = true }
    }
  }

  private func frame(_ message: ScreenSharingClipboardMessage) throws -> String {
    try #require(VNCClipboardRelayMessage.encode(message))
  }

  @Test func onceTheServerOffersItsClipboardTransfersUseTheSideChannelAndCutTextStopsBeingShared() async throws {
    let channel = FakeChannel()
    let translator = VNCInputTranslator(width: 100, height: 100, keys: VNCKeyTranslator { _, _ in nil })
    let emulator = VNCHostEmulator(translator: translator, leaseChannel: channel, viewerName: "Studio") { _ in }
    let viewer = Viewer(emulator)
    var sends = channel.sends.makeAsyncIterator()
    emulator.sharing = true

    channel.onControlText?(#"{"type":"clipboard-host","richContent":true}"#)
    await awaitObserved { viewer.richClipboard }
    #expect(await sends.next() == #"{"type":"clipboard-viewer","sharing":true}"#)

    let id = UUID()
    let messages: [ScreenSharingClipboardMessage] = [
      .begin(id: id, bytes: 3, richContent: true), .chunk(id: id, index: 0, data: Data([1, 2, 3])), .end(id: id),
    ]
    for message in messages { emulator.clipboardChannel.send(message) }
    for message in messages {
      let sent = try #require(await sends.next())
      #expect(VNCClipboardRelayMessage.decode(sent) == .transfer(message))
    }

    emulator.serverCutText("copied with xclip")
    channel.onControlText?(try frame(.ack(id: id, nextIndex: 1)))
    channel.onControlText?(try frame(.result(id: id, error: nil)))
    await awaitObserved { viewer.received.count == 2 }
    #expect(viewer.received == [.ack(id: id, nextIndex: 1), .result(id: id, error: nil)])

    emulator.sharing = false
    #expect(await sends.next() == #"{"type":"clipboard-viewer","sharing":false}"#)
  }

  @Test func withoutTheOfferCutTextIsStillShared() async {
    let channel = FakeChannel()
    let translator = VNCInputTranslator(width: 100, height: 100, keys: VNCKeyTranslator { _, _ in nil })
    let emulator = VNCHostEmulator(translator: translator, leaseChannel: channel, viewerName: "Studio") { _ in }
    let viewer = Viewer(emulator)
    emulator.sharing = true
    emulator.serverCutText("plain")
    await awaitObserved { !viewer.received.isEmpty }
    guard case .begin(_, 5, nil)? = viewer.received.first else {
      Issue.record("expected a plain-text transfer, got \(viewer.received)")
      return
    }
    #expect(!viewer.richClipboard)
  }

  @Test func relayFramesDecodeOnlyWhenTheyAreClipboardFrames() throws {
    #expect(
      VNCClipboardRelayMessage.decode(#"{"type":"clipboard-host","richContent":true}"#) == .host(richContent: true))
    #expect(VNCClipboardRelayMessage.decode(#"{"type":"granted"}"#) == nil)
    #expect(
      VNCClipboardRelayMessage.decode(
        #"{"type":"clipboard","version":2,"message":{"end":{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF"}}}"#) == nil)
    let message = ScreenSharingClipboardMessage.chunk(id: UUID(), index: 7, data: Data([0, 255]))
    #expect(VNCClipboardRelayMessage.decode(try frame(message)) == .transfer(message))
    #expect(
      VNCClipboardRelayMessage.decode(
        #"{"type":"clipboard","version":1,"message":{"result":{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF"}}}"#)
        == .transfer(.result(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, error: nil)))
  }
}
