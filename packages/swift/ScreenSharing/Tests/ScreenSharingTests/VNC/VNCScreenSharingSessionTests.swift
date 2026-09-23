import ScreenSharing
import CodevisorTestSupport
import CoreVideo
import Foundation
import ScreenSharingTesting
import Testing
@testable import ScreenSharing

/// The VNC viewing session against the loopback server: frames into the
/// mailbox, the locally granted control lease driving RFB input, the
/// clipboard bridge, and how the read loop's end is reported.
@MainActor
struct VNCScreenSharingSessionTests {
  @MainActor
  final class Harness {
    let server: RFBLoopbackServer
    let session: VNCScreenSharingSession
    var transports: [String] = []

    init(configuration: RFBLoopbackServer.Configuration = .init()) async throws {
      server = try await RFBLoopbackServer(configuration: configuration)
      let client = try RFBClient(transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
      let outcome = try await client.connect(password: "secret")
      session = VNCScreenSharingSession(
        client: client, parameters: outcome.parameters, keys: VNCKeyTranslator(layout: { _, _ in "a" }))
      session.onConnectionChanged = { [self] in transports.append($0) }
    }

    func stop() {
      session.close()
      server.stop()
    }
  }

  @Test func framesReachTheMailboxAsBGRAPixelBuffers() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    try harness.server.paint(RFBRectangle(x: 0, y: 0, width: 64, height: 48), blue: 1, green: 2, red: 3)
    harness.server.enqueue([.raw(RFBRectangle(x: 0, y: 0, width: 64, height: 48))])
    #expect(await awaitPolled { harness.session.frames.isHolding })
    let frame = try #require(harness.session.frames.take())
    #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 64 && CVPixelBufferGetHeight(frame.pixelBuffer) == 48)
    #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
    let base = CVPixelBufferGetBaseAddress(frame.pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let pixel = base + 10 * CVPixelBufferGetBytesPerRow(frame.pixelBuffer) + 10 * 4
    #expect([pixel[0], pixel[1], pixel[2], pixel[3]] == [1, 2, 3, 255])
    CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly)
    #expect(harness.session.metrics.snapshot().labels["videoSize"] == "64 × 48")

    harness.server.enqueue([.desktopSize(width: 32, height: 16)])
    #expect(await awaitPolled { harness.session.metrics.snapshot().labels["videoSize"] == "32 × 16" })
    harness.server.enqueue([.raw(RFBRectangle(x: 0, y: 0, width: 32, height: 16))])
    #expect(await awaitPolled { harness.session.frames.take().map { CVPixelBufferGetWidth($0.pixelBuffer) } == 32 })
  }

  @Test func updatesFeedTheSessionsVNCMetrics() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    // The first (non-incremental) update is the whole 64 × 48 frame, raw.
    #expect(await awaitPolled { harness.session.metrics.snapshot().counters["vncUpdatesPublished"] == 1 })
    let snapshot = harness.session.metrics.snapshot()
    #expect(snapshot.counters["vncBytesReceived"] == 4 + 12 + 64 * 48 * 4)
    #expect(snapshot.timings["vncUpdateLatency"]?.count == 1)
    #expect(snapshot.counters["vncBytesCopied"] == 64 * 48 * 4, "The first update fills a new buffer whole.")
    #expect(await harness.session.statistics() == ["vnc.transport": "TCP"])
  }

  @Test func pushedUpdatesAndFenceRoundTripsReachTheMetrics() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.continuousUpdates = true
    configuration.fences = true
    let harness = try await Harness(configuration: configuration)
    defer { harness.stop() }
    #expect(await awaitPolled { harness.session.metrics.snapshot().labels["vncUpdateMode"] == "continuous" })
    #expect(await awaitPolled { harness.server.isContinuous })
    harness.server.enqueue([.raw(RFBRectangle(x: 0, y: 0, width: 4, height: 4))])
    #expect(await awaitPolled { (harness.session.metrics.snapshot().timings["vncRoundTrip"]?.count ?? 0) >= 1 })
  }

  @Test func theServersPointerReachesTheViewerInOrder() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.cursor = RFBCursorTestShapes.corner
    let harness = try await Harness(configuration: configuration)
    defer { harness.stop() }
    var received: [ScreenSharingCursorUpdate] = []
    harness.session.onCursorChanged = { received.append($0) }
    #expect(await awaitPolled { received == [.shape(RFBCursorTestShapes.corner)] })
    #expect(await awaitPolled { harness.server.isRequestPending })
    harness.server.movePointer(to: RFBPoint(x: 5, y: 6))
    #expect(await awaitPolled { received.last == .position(RFBPoint(x: 5, y: 6)) })
    #expect(harness.session.metrics.snapshot().counters["vncCursorShapes"] == 1)
  }

  @Test func controlIsGrantedLocallyAndInputReachesTheServer() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let control = try #require(harness.session.control)
    let received = ScreenSharingMessageLog<ScreenSharingControlMessage>()
    control.onMessage = { received.append($0) }
    let request = UUID()
    control.send(.request(id: request))
    #expect(await awaitPolled { received.messages.count == 1 })
    guard case .grant(let granted, let lease) = received.messages[0] else { Issue.record("no grant"); return }
    #expect(granted == request)
    let centre = ScreenSharingPointer(x: 0.5, y: 0.5)
    control.send(
      .input(lease: lease, sequence: 1, event: .button(centre, button: 0, down: true, clicks: 1, modifiers: 0)))
    control.send(.input(lease: lease, sequence: 2, event: .key(code: 36, down: true, repeatKey: false, modifiers: 0)))
    #expect(await awaitPolled { harness.server.received.contains(.keyEvent(keysym: RFBKeysym.return, down: true)) })
    #expect(harness.server.received.contains(.pointerEvent(buttons: 1, x: 32, y: 24)))
    // Releasing the lease releases the held button; input under the old lease is dropped.
    control.send(.release(lease: lease))
    #expect(await awaitPolled { harness.server.received.contains(.pointerEvent(buttons: 0, x: 32, y: 24)) })
    control.send(.input(lease: lease, sequence: 3, event: .key(code: 53, down: true, repeatKey: false, modifiers: 0)))
    control.send(.request(id: UUID()))
    #expect(await awaitPolled { received.messages.count == 2 })
    guard case .grant(_, let second) = received.messages[1] else { Issue.record("no second grant"); return }
    control.send(.input(lease: second, sequence: 1, event: .key(code: 48, down: true, repeatKey: false, modifiers: 0)))
    #expect(await awaitPolled { harness.server.received.contains(.keyEvent(keysym: RFBKeysym.tab, down: true)) })
    #expect(!harness.server.received.contains(.keyEvent(keysym: RFBKeysym.escape, down: true)))
  }

  @Test func clipboardBridgesCutTextBothWays() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let channel = try #require(harness.session.clipboard)
    let received = ScreenSharingMessageLog<ScreenSharingClipboardMessage>()
    channel.onMessage = { received.append($0) }
    let empty = UUID()
    channel.send(.read(id: empty))
    #expect(await awaitPolled { received.messages.count == 1 })
    #expect(received.messages[0] == .result(id: empty, error: "The VNC server has not shared any clipboard text yet."))

    harness.server.sendCutText("from server")
    #expect(await awaitPolled { harness.session.metrics.snapshot().counters["vncServerCutTexts"] == 1 })
    let read = UUID()
    channel.send(.read(id: read))
    #expect(await awaitPolled { received.messages.count == 2 })
    #expect(received.messages[1] == .begin(id: read, bytes: 11))
    channel.send(.ack(id: read, nextIndex: 0))
    #expect(await awaitPolled { received.messages.count == 3 })
    #expect(received.messages[2] == .chunk(id: read, index: 0, data: Data("from server".utf8)))
    channel.send(.ack(id: read, nextIndex: 1))
    #expect(await awaitPolled { received.messages.count == 4 })
    #expect(received.messages[3] == .end(id: read))
    channel.send(.result(id: read, error: nil))

    let write = UUID()
    channel.send(.begin(id: write, bytes: 5))
    #expect(await awaitPolled { received.messages.count == 5 })
    #expect(received.messages[4] == .ack(id: write, nextIndex: 0))
    channel.send(.chunk(id: write, index: 0, data: Data("hello".utf8)))
    #expect(await awaitPolled { received.messages.count == 6 })
    #expect(received.messages[5] == .ack(id: write, nextIndex: 1))
    channel.send(.end(id: write))
    #expect(await awaitPolled { received.messages.count == 7 })
    #expect(received.messages[6] == .result(id: write, error: nil))
    #expect(await awaitPolled { harness.server.received.contains(.clientCutText("hello")) })
  }

  @Test func serverCloseIsDisconnectedAndCloseIsIdempotent() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    harness.server.enqueue([.raw(RFBRectangle(x: 0, y: 0, width: 1, height: 1))])
    #expect(await awaitPolled { harness.session.frames.isHolding })
    harness.server.closeClient()
    #expect(await harness.session.outcome() as? RFBError == .connectionClosed)
    #expect(await awaitPolled { harness.transports == ["disconnected"] })
    #expect(harness.session.failure == nil)
    harness.session.close()
    harness.session.close()
    #expect(harness.session.control?.isAvailable == false && harness.session.clipboard?.isAvailable == false)
    #expect(!harness.session.frames.isHolding)
  }

  @Test func protocolErrorsAreFailures() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    harness.server.write([200])
    #expect(await harness.session.outcome() as? RFBError == .malformed("unknown server message 200"))
    #expect(await awaitPolled { harness.transports == ["failed"] })
    #expect(harness.session.failure?.contains("invalid message") == true)
  }
}

/// Messages a channel delivered, for polling from tests.
@MainActor
final class ScreenSharingMessageLog<Message> {
  private(set) var messages: [Message] = []
  func append(_ message: Message) { messages.append(message) }
}
