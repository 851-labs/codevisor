import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// The whole client against the loopback server over TCP: handshake, the
/// update-request loop, every encoding, events, input and failure modes.
struct RFBClientLoopbackTests {
  struct Snapshot: Sendable {
    let update: RFBUpdate
    let width: Int
    let height: Int
    let pixels: [UInt8]
    func pixel(x: Int, y: Int) -> [UInt8] {
      let index = (y * width + x) * 4
      return Array(pixels[index..<index + 3])
    }
  }

  /// A connected client whose `run` feeds snapshots and events into streams.
  final class Harness: @unchecked Sendable {
    let server: RFBLoopbackServer
    let client: RFBClient
    let outcome: RFBHandshake.Outcome
    let updates: AsyncStream<Snapshot>
    let events: AsyncStream<RFBServerEvent>
    private var updateIterator: AsyncStream<Snapshot>.AsyncIterator
    private var eventIterator: AsyncStream<RFBServerEvent>.AsyncIterator
    let run: Task<any Error, Never>

    init(configuration: RFBLoopbackServer.Configuration = .init(), password: String? = "secret") async throws {
      server = try await RFBLoopbackServer(configuration: configuration)
      client = try RFBClient(transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
      outcome = try await client.connect(password: password)
      let (updates, updateContinuation) = AsyncStream<Snapshot>.makeStream()
      let (events, eventContinuation) = AsyncStream<RFBServerEvent>.makeStream()
      self.updates = updates
      self.events = events
      updateIterator = updates.makeAsyncIterator()
      eventIterator = events.makeAsyncIterator()
      let client = client
      run = Task {
        do {
          try await client.run(
            onUpdate: { framebuffer, update in
              updateContinuation.yield(
                Snapshot(
                  update: update, width: framebuffer.width, height: framebuffer.height, pixels: framebuffer.pixels))
            },
            onEvent: { eventContinuation.yield($0) })
        } catch {
          updateContinuation.finish()
          eventContinuation.finish()
          return error
        }
      }
    }

    func nextUpdate() async -> Snapshot? { await updateIterator.next() }
    func nextEvent() async -> RFBServerEvent? { await eventIterator.next() }
    func stop() { client.close(); server.stop() }
  }

  @Test func handshakeConfiguresTheFramebufferAndRequestsTheWholeScreen() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    #expect(harness.outcome.parameters == .init(width: 64, height: 48, pixelFormat: .bgra32, name: "Loopback"))
    #expect(harness.client.framebuffer.width == 64)
    let first = await harness.nextUpdate()
    #expect(first?.update == RFBUpdate(rectangles: [RFBRectangle(x: 0, y: 0, width: 64, height: 48)], resized: false))
    #expect(await awaitPolled { harness.server.isRequestPending })
    #expect(
      harness.server.received.prefix(3) == [
        .setPixelFormat(.bgra32), .setEncodings([7, 16, 1, 0, -223, -239, -232, -312, -313, -308, -1_063_131_698]),
        .framebufferUpdateRequest(incremental: false, RFBRectangle(x: 0, y: 0, width: 64, height: 48)),
      ])
    #expect(
      harness.server.received.last
        == .framebufferUpdateRequest(incremental: true, RFBRectangle(x: 0, y: 0, width: 64, height: 48)))
  }

  @Test func rawCopyRectAndZRLEUpdatesLandInTheFramebuffer() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    _ = await harness.nextUpdate()
    try harness.server.paint(RFBRectangle(x: 0, y: 0, width: 8, height: 8), blue: 1, green: 2, red: 3)
    harness.server.enqueue([.raw(RFBRectangle(x: 0, y: 0, width: 8, height: 8))])
    let raw = await harness.nextUpdate()
    #expect(raw?.pixel(x: 7, y: 7) == [1, 2, 3])
    #expect(raw?.pixel(x: 8, y: 8) == [0, 0, 0])
    harness.server.enqueue([.copy(RFBRectangle(x: 20, y: 20, width: 8, height: 8), fromX: 0, fromY: 0)])
    let copied = await harness.nextUpdate()
    #expect(copied?.pixel(x: 27, y: 27) == [1, 2, 3])
    try harness.server.paint(RFBRectangle(x: 0, y: 0, width: 64, height: 48), blue: 9, green: 9, red: 9)
    try harness.server.paint(RFBRectangle(x: 10, y: 10, width: 1, height: 1), blue: 4, green: 5, red: 6)
    harness.server.enqueue([.zrle(RFBRectangle(x: 0, y: 0, width: 64, height: 48))])
    let zrle = await harness.nextUpdate()
    #expect(zrle?.pixel(x: 10, y: 10) == [4, 5, 6])
    #expect(zrle?.pixel(x: 63, y: 47) == [9, 9, 9])
    // A second ZRLE rectangle continues the same zlib stream.
    harness.server.enqueue([
      .zrle(RFBRectangle(x: 0, y: 0, width: 32, height: 32)), .zrle(RFBRectangle(x: 32, y: 0, width: 32, height: 48)),
    ])
    let again = await harness.nextUpdate()
    #expect(again?.update.rectangles.count == 2)
    #expect(again?.pixel(x: 10, y: 10) == [4, 5, 6])
  }

  @Test func desktopSizeResizesBeforeTheRepaint() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    _ = await harness.nextUpdate()
    harness.server.enqueue([.desktopSize(width: 100, height: 20)])
    let resized = await harness.nextUpdate()
    #expect(resized?.update == RFBUpdate(rectangles: [], resized: true))
    #expect(resized?.width == 100 && resized?.height == 20)
    try harness.server.paint(RFBRectangle(x: 99, y: 19, width: 1, height: 1), blue: 7, green: 7, red: 7)
    harness.server.enqueue([.raw(RFBRectangle(x: 96, y: 16, width: 4, height: 4))])
    let painted = await harness.nextUpdate()
    #expect(painted?.pixel(x: 99, y: 19) == [7, 7, 7])
    #expect(await awaitPolled { harness.server.isRequestPending })
    #expect(
      harness.server.received.last
        == .framebufferUpdateRequest(incremental: true, RFBRectangle(x: 0, y: 0, width: 100, height: 20)))
  }

  @Test func eventsAndInputTravelBothWays() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    _ = await harness.nextUpdate()
    harness.server.sendBell()
    harness.server.sendCutText("from server")
    #expect(await harness.nextEvent() == .bell)
    #expect(await harness.nextEvent() == .serverCutText("from server"))
    try await harness.client.send(.keyEvent(keysym: 0x61, down: true))
    try await harness.client.send(.pointerEvent(buttons: 1, x: 5, y: 6))
    try await harness.client.send(.clientCutText("to server"))
    #expect(await awaitPolled { harness.server.received.contains(.clientCutText("to server")) })
    #expect(harness.server.received.contains(.keyEvent(keysym: 0x61, down: true)))
    #expect(harness.server.received.contains(.pointerEvent(buttons: 1, x: 5, y: 6)))
  }

  @Test func serverCloseEndsTheRunWithConnectionClosed() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    _ = await harness.nextUpdate()
    harness.server.closeClient()
    let error = await harness.run.value
    #expect(error as? RFBError == .connectionClosed)
    await #expect(throws: RFBError.self) { try await harness.client.send(.keyEvent(keysym: 1, down: true)) }
  }

  @Test func malformedAndUnsupportedServerMessagesAreTerminal() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    _ = await harness.nextUpdate()
    harness.server.write([200])
    #expect(await harness.run.value as? RFBError == .malformed("unknown server message 200"))

    // Hextile (5) is never advertised (Tight, 7, now is: 851-2313).
    let hextile = try await Harness()
    defer { hextile.stop() }
    _ = await hextile.nextUpdate()
    hextile.server.write([0, 0] + u16(1) + u16(0) + u16(0) + u16(1) + u16(1) + u32(5))
    #expect(await hextile.run.value as? RFBError == .unsupportedEncoding(5))
  }

  @Test func wrongPasswordAndNoneSecurityAndVersion33() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    let client = try RFBClient(transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
    await #expect(throws: RFBError.authenticationFailed("Authentication failed")) {
      try await client.connect(password: "wrong")
    }
    client.close()

    var open = RFBLoopbackServer.Configuration()
    open.securityTypes = [1]
    open.password = nil
    open.version = .v3_3
    let openHarness = try await Harness(configuration: open, password: nil)
    defer { openHarness.stop() }
    #expect(openHarness.outcome.version == .v3_3)
    #expect(openHarness.outcome.security == .none)
    #expect(await openHarness.nextUpdate() != nil)
  }

  @Test func fullHDZRLEFrameDecodes() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.width = 1920
    configuration.height = 1080
    configuration.encoding = .zrle
    let harness = try await Harness(configuration: configuration)
    defer { harness.stop() }
    // The server answers the client's initial request the moment it
    // arrives, so painting before consuming that reply races it: the
    // snapshot could land between the two paints. Settle it first; the
    // enqueued frame is then encoded only after both paints.
    let initial = await harness.nextUpdate()
    #expect(initial?.width == 1920 && initial?.height == 1080)
    try harness.server.paint(RFBRectangle(x: 0, y: 0, width: 1920, height: 1080), blue: 1, green: 2, red: 3)
    try harness.server.paint(RFBRectangle(x: 1000, y: 500, width: 1, height: 1), blue: 4, green: 4, red: 4)
    harness.server.enqueue([.zrle(RFBRectangle(x: 0, y: 0, width: 1920, height: 1080))])
    let frame = await harness.nextUpdate()
    #expect(frame?.update.rectangles == [RFBRectangle(x: 0, y: 0, width: 1920, height: 1080)])
    #expect(frame?.pixel(x: 1919, y: 1079) == [1, 2, 3])
    #expect(frame?.pixel(x: 1000, y: 500) == [4, 4, 4])
  }
}
