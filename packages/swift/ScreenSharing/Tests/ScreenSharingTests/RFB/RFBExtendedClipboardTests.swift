import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// Extended Clipboard (0xC0A1E5CE), 851-2316: UTF-8 text through the
/// caps / notify / request / provide handshake instead of Latin-1.
@MainActor
struct RFBExtendedClipboardTests {
  nonisolated static let text = "héllo — 日本語 😀\nline two"
  typealias Message = RFBExtendedClipboard.Message

  // MARK: L1 — the codec

  @Test(arguments: [
    Message.caps(
      formats: RFBExtendedClipboard.text, actions: RFBExtendedClipboard.request | RFBExtendedClipboard.provide,
      maximumSizes: [4096]),
    .request(formats: RFBExtendedClipboard.text), .peek, .notify(formats: RFBExtendedClipboard.text),
    .provide(text: RFBExtendedClipboardTests.text), .provide(text: nil), .provide(text: ""),
  ])
  func messagesRoundTrip(_ message: Message) throws {
    #expect(try RFBExtendedClipboard.decode(try RFBExtendedClipboard.encode(message)) == message)
  }

  @Test func textTravelsAsNulTerminatedCRLFUTF8() throws {
    let bytes = try RFBExtendedClipboard.encode(.provide(text: "a\nb"))
    #expect(Array(bytes.prefix(4)) == [0x10, 0, 0, 1], "provide | text")
    let inflated = try RFBZlibInflater().inflate(Array(bytes.dropFirst(4)))
    #expect(inflated == [0, 0, 0, 5, 0x61, 0x0D, 0x0A, 0x62, 0])
  }

  @Test func malformedMessagesAreRejected() throws {
    #expect(throws: RFBError.self) { try RFBExtendedClipboard.decode([0, 0]) }
    #expect(throws: RFBError.self) { try RFBExtendedClipboard.decode([0, 0, 0, 1]) }  // no action
    #expect(throws: RFBError.self) { try RFBExtendedClipboard.decode([0x10, 0, 0, 1, 9, 9, 9]) }  // not zlib
    #expect(throws: RFBError.self) { try RFBExtendedClipboard.decode([0x01, 0, 0, 1]) }  // caps without sizes
  }

  @Test func theClientMessageIsANegativeLengthCutText() async throws {
    let message = RFBClientMessage.extendedClipboard(.notify(formats: RFBExtendedClipboard.text))
    #expect(message.encoded == [6, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFC, 0x08, 0, 0, 1])
    let stream = RFBInputStream(transport: ScriptedTransport(message.encoded))
    #expect(try await RFBClientMessage.read(from: stream) == message)
  }

  // MARK: L2 — the session, driven like the product's clipboard menu

  final class Viewer {
    let server: RFBLoopbackServer
    let session: VNCScreenSharingSession
    var transfer: ScreenSharingClipboardTransfer!
    var received: [String] = []
    var finished: [String?] = []
    @MainActor init(extended: Bool) async throws {
      var configuration = RFBLoopbackServer.Configuration()
      configuration.extendedClipboard = extended
      server = try await RFBLoopbackServer(configuration: configuration)
      let client = try RFBClient(transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
      let outcome = try await client.connect(password: "secret")
      session = VNCScreenSharingSession(client: client, parameters: outcome.parameters)
      let channel = try #require(session.clipboard)
      transfer = ScreenSharingClipboardTransfer(
        send: { channel.send($0) }, read: { RFBExtendedClipboardTests.text },
        write: { [unowned self] in self.received.append($0) })
      transfer.onFinished = { [unowned self] in self.finished.append($0) }
      channel.onMessage = { [unowned self] in self.transfer.receive($0) }
    }
    @MainActor func stop() {
      session.close()
      server.stop()
    }
  }

  @Test func textReachesTheServerAsUTF8() async throws {
    let viewer = try await Viewer(extended: true)
    defer { viewer.stop() }
    // The session answers the server's caps before anything else.
    #expect(
      await awaitPolled {
        viewer.server.received.contains { if case .extendedClipboard(.caps) = $0 { true } else { false } }
      })
    viewer.transfer.sendText(Self.text)
    #expect(await awaitPolled { viewer.server.clipboardTextsReceived == [Self.text] })
    #expect(
      !viewer.server.received.contains { if case .clientCutText = $0 { true } else { false } }, "No Latin-1 copy.")
  }

  @Test func theServersTextArrivesAsUTF8() async throws {
    let viewer = try await Viewer(extended: true)
    defer { viewer.stop() }
    #expect(
      await awaitPolled {
        viewer.server.received.contains { if case .extendedClipboard(.caps) = $0 { true } else { false } }
      })
    viewer.server.setClipboard(Self.text)
    // notify → the session requests at once → provide.
    #expect(
      await awaitPolled { viewer.session.metrics.snapshot().counters["vncExtendedClipboardMessages", default: 0] >= 3 })
    viewer.transfer.requestText()
    #expect(await awaitPolled { viewer.received == [Self.text] })
  }

  @Test func aServerWithoutItStillGetsLatin1() async throws {
    let viewer = try await Viewer(extended: false)
    defer { viewer.stop() }
    #expect(await awaitPolled { viewer.server.isRequestPending })
    viewer.transfer.sendText("plain")
    #expect(await awaitPolled { viewer.server.received.contains(.clientCutText("plain")) })
  }
}
