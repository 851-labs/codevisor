import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// The loopback server is a fixture every other suite trusts, so the promises
/// it makes — an ephemeral port, a faithful message log, rectangles delivered
/// on the next request — are tested in their own right here.
struct RFBLoopbackServerTests {
  /// One connected client, with its updates and events on streams.
  final class Client: @unchecked Sendable {
    let client: RFBClient
    let outcome: RFBHandshake.Outcome
    private var updates: AsyncStream<RFBClientLoopbackTests.Snapshot>.AsyncIterator
    private var events: AsyncStream<RFBServerEvent>.AsyncIterator
    let run: Task<any Error, Never>

    init(to server: RFBLoopbackServer, password: String? = "secret") async throws {
      client = try RFBClient(transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
      outcome = try await client.connect(password: password)
      let (updateStream, updateContinuation) = AsyncStream<RFBClientLoopbackTests.Snapshot>.makeStream()
      let (eventStream, eventContinuation) = AsyncStream<RFBServerEvent>.makeStream()
      updates = updateStream.makeAsyncIterator()
      events = eventStream.makeAsyncIterator()
      let client = client
      run = Task {
        do {
          try await client.run(
            onUpdate: { framebuffer, update in
              updateContinuation.yield(
                .init(update: update, width: framebuffer.width, height: framebuffer.height, pixels: framebuffer.pixels))
            }, onEvent: { eventContinuation.yield($0) })
        } catch {
          updateContinuation.finish()
          eventContinuation.finish()
          return error
        }
      }
    }

    func nextUpdate() async -> RFBClientLoopbackTests.Snapshot? { await updates.next() }
    func nextEvent() async -> RFBServerEvent? { await events.next() }
    func close() { client.close() }
  }

  private func open(_ configuration: RFBLoopbackServer.Configuration = .init()) async throws -> RFBLoopbackServer {
    try await RFBLoopbackServer(configuration: configuration)
  }

  // MARK: The listener

  @Test func eachServerBindsItsOwnEphemeralPort() async throws {
    let first = try await open()
    defer { first.stop() }
    let second = try await open()
    defer { second.stop() }
    #expect(first.port != 0)
    #expect(second.port != 0)
    #expect(first.port != second.port)
  }

  /// Port 0 is the explicit spelling of "any port", so configuring it takes
  /// the same path as a real port number without pinning one.
  @Test func anExplicitPortOfZeroStillMeansEphemeral() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.port = 0
    let server = try await open(configuration)
    defer { server.stop() }
    #expect(server.port != 0)
  }

  @Test func stoppingTwiceIsHarmless() async throws {
    let server = try await open()
    server.stop()
    server.stop()
  }

  // MARK: Configuration

  @Test func serverInitReportsTheConfiguredDesktop() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.width = 200
    configuration.height = 120
    configuration.name = "Rig"
    let server = try await open(configuration)
    defer { server.stop() }
    let client = try await Client(to: server)
    defer { client.close() }
    #expect(client.outcome.parameters == .init(width: 200, height: 120, pixelFormat: .bgra32, name: "Rig"))
    #expect(server.framebuffer.width == 200 && server.framebuffer.height == 120)
  }

  @Test(arguments: [RFBProtocolVersion.v3_3, .v3_7, .v3_8])
  func theConfiguredVersionIsTheOneNegotiated(_ version: RFBProtocolVersion) async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.version = version
    let server = try await open(configuration)
    defer { server.stop() }
    let client = try await Client(to: server)
    defer { client.close() }
    #expect(client.outcome.version == version)
    #expect(client.outcome.security == .vncAuthentication)
  }

  @Test func offeringOnlyNoneSkipsAuthentication() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.securityTypes = [RFBSecurityType.none.rawValue]
    configuration.password = nil
    let server = try await open(configuration)
    defer { server.stop() }
    let client = try await Client(to: server, password: nil)
    defer { client.close() }
    #expect(client.outcome.security == .none)
    #expect(await client.nextUpdate() != nil)
  }

  /// On 3.8 the failure carries the server's reason; on 3.7 there is no reason
  /// on the wire, so the client supplies its own wording.
  @Test func awrongPasswordIsRejectedWithTheServersReasonOn38() async throws {
    let server = try await open()
    defer { server.stop() }
    let client = try RFBClient(transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
    defer { client.close() }
    await #expect(throws: RFBError.authenticationFailed("Authentication failed")) {
      try await client.connect(password: "wrong")
    }
  }

  @Test func aWrongPasswordOn37GetsTheClientsOwnWording() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.version = .v3_7
    let server = try await open(configuration)
    defer { server.stop() }
    let client = try RFBClient(transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
    defer { client.close() }
    await #expect(throws: RFBError.authenticationFailed("The VNC server rejected the password.")) {
      try await client.connect(password: "wrong")
    }
  }

  @Test func anUnsupportedSecurityTypeEndsTheConnection() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.securityTypes = [16, 18]
    let server = try await open(configuration)
    defer { server.stop() }
    let client = try RFBClient(transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
    defer { client.close() }
    await #expect(throws: RFBError.securityUnsupported([16, 18])) { try await client.connect(password: "secret") }
  }

  // MARK: The message log

  @Test func everyClientMessageIsLoggedInArrivalOrder() async throws {
    let server = try await open()
    defer { server.stop() }
    let client = try await Client(to: server)
    defer { client.close() }
    _ = await client.nextUpdate()
    try await client.client.send(.keyEvent(keysym: 0x41, down: true))
    try await client.client.send(.keyEvent(keysym: 0x41, down: false))
    try await client.client.send(.pointerEvent(buttons: 4, x: 11, y: 22))
    try await client.client.send(.clientCutText("hello"))
    #expect(await awaitPolled { server.received.contains(.clientCutText("hello")) })
    let input = server.received.filter {
      if case .framebufferUpdateRequest = $0 { return false }
      if case .setPixelFormat = $0 { return false }
      if case .setEncodings = $0 { return false }
      return true
    }
    #expect(
      input == [
        .keyEvent(keysym: 0x41, down: true), .keyEvent(keysym: 0x41, down: false),
        .pointerEvent(buttons: 4, x: 11, y: 22), .clientCutText("hello"),
      ])
    #expect(
      server.received.prefix(2) == [
        .setPixelFormat(.bgra32), .setEncodings([7, 16, 1, 0, -223, -239, -232, -312, -313, -308, -1_063_131_698]),
      ])
  }

  /// The callback sees the same messages as the log, which is what the rig's
  /// live view is built on.
  @Test func theMessageCallbackSeesEveryMessageToo() async throws {
    let server = try await open()
    defer { server.stop() }
    let observed = MessageBox()
    server.onClientMessage = { observed.append($0) }
    let client = try await Client(to: server)
    defer { client.close() }
    try await client.client.send(.clientCutText("via callback"))
    #expect(await awaitPolled { observed.messages.contains(.clientCutText("via callback")) })
    #expect(observed.messages == server.received)
  }

  @Test func connectionsAreCountedAndTheServerTakesOneClientAtATime() async throws {
    let server = try await open()
    defer { server.stop() }
    #expect(server.connectionCount == 0)
    let first = try await Client(to: server)
    _ = await first.nextUpdate()
    #expect(server.connectionCount == 1)
    server.closeClient()
    #expect(await first.run.value as? RFBError == .connectionClosed)
    let second = try await Client(to: server)
    defer { second.close() }
    _ = await second.nextUpdate()
    #expect(await awaitPolled { server.connectionCount == 2 })
  }

  // MARK: Delivering rectangles

  /// The client keeps one incremental request outstanding, so the server is
  /// always able to push the next rectangle without being asked again.
  @Test func anIdleClientLeavesARequestPending() async throws {
    let server = try await open()
    defer { server.stop() }
    let client = try await Client(to: server)
    defer { client.close() }
    _ = await client.nextUpdate()
    #expect(await awaitPolled { server.isRequestPending })
    try server.paint(RFBRectangle(x: 0, y: 0, width: 4, height: 4), blue: 1, green: 2, red: 3)
    server.enqueue([.raw(RFBRectangle(x: 0, y: 0, width: 4, height: 4))])
    #expect(await client.nextUpdate()?.pixel(x: 3, y: 3) == [1, 2, 3])
  }

  /// Rectangles enqueued back to back all arrive, in order. Whether they are
  /// coalesced into one update depends on when the client's next request lands,
  /// so the grouping is deliberately not asserted — only that nothing is lost.
  @Test func rectanglesEnqueuedBackToBackAllArrive() async throws {
    let server = try await open()
    defer { server.stop() }
    let client = try await Client(to: server)
    defer { client.close() }
    _ = await client.nextUpdate()
    let first = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let second = RFBRectangle(x: 4, y: 4, width: 2, height: 2)
    try server.paint(first, blue: 1, green: 0, red: 0)
    server.enqueue([.raw(first)])
    try server.paint(second, blue: 2, green: 0, red: 0)
    server.enqueue([.raw(second)])
    var rectangles: [RFBRectangle] = []
    var latest: RFBClientLoopbackTests.Snapshot?
    while rectangles.count < 2, let update = await client.nextUpdate() {
      rectangles += update.update.rectangles
      latest = update
    }
    #expect(rectangles == [first, second])
    #expect(latest?.pixel(x: 1, y: 1) == [1, 0, 0])
    #expect(latest?.pixel(x: 5, y: 5) == [2, 0, 0])
  }

  @Test func rawPixelsArriveByteForByte() async throws {
    let server = try await open()
    defer { server.stop() }
    let client = try await Client(to: server)
    defer { client.close() }
    _ = await client.nextUpdate()
    let rect = RFBRectangle(x: 5, y: 7, width: 3, height: 2)
    let pixels = (0..<(3 * 2 * 4)).map { UInt8($0 * 3) }
    try server.paint(rect, pixels: pixels)
    server.enqueue([.raw(rect)])
    let update = try #require(await client.nextUpdate())
    for row in 0..<2 {
      for column in 0..<3 {
        let index = (row * 3 + column) * 4
        #expect(update.pixel(x: 5 + column, y: 7 + row) == Array(pixels[index..<index + 3]))
      }
    }
  }

  /// A ZRLE reply compresses solid tiles and raw tiles differently; both have
  /// to come back as the pixels that went in.
  @Test func zrleRepliesRoundTripSolidAndMixedTiles() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.encoding = .zrle
    configuration.width = 70
    configuration.height = 70
    let server = try await open(configuration)
    defer { server.stop() }
    try server.paint(RFBRectangle(x: 0, y: 0, width: 70, height: 70), blue: 8, green: 8, red: 8)
    try server.paint(RFBRectangle(x: 65, y: 65, width: 1, height: 1), blue: 1, green: 2, red: 3)
    let client = try await Client(to: server)
    defer { client.close() }
    let update = try #require(await client.nextUpdate())
    #expect(update.pixel(x: 0, y: 0) == [8, 8, 8])  // a solid tile
    #expect(update.pixel(x: 65, y: 65) == [1, 2, 3])  // the raw tile in the corner
    #expect(update.pixel(x: 69, y: 69) == [8, 8, 8])
  }

  /// CopyRect moves pixels on the server's own framebuffer as well, so the
  /// two sides stay in step for whatever is sent next.
  @Test func copyRectMovesPixelsOnBothSides() async throws {
    let server = try await open()
    defer { server.stop() }
    let client = try await Client(to: server)
    defer { client.close() }
    _ = await client.nextUpdate()
    try server.paint(RFBRectangle(x: 0, y: 0, width: 4, height: 4), blue: 6, green: 5, red: 4)
    server.enqueue([.raw(RFBRectangle(x: 0, y: 0, width: 4, height: 4))])
    _ = await client.nextUpdate()
    server.enqueue([.copy(RFBRectangle(x: 10, y: 10, width: 4, height: 4), fromX: 0, fromY: 0)])
    #expect(await client.nextUpdate()?.pixel(x: 13, y: 13) == [6, 5, 4])
    #expect(server.framebuffer.pixel(x: 13, y: 13) == (6, 5, 4))
  }

  @Test func desktopSizeResizesTheServersFramebufferToo() async throws {
    let server = try await open()
    defer { server.stop() }
    let client = try await Client(to: server)
    defer { client.close() }
    _ = await client.nextUpdate()
    server.enqueue([.desktopSize(width: 30, height: 20)])
    let update = try #require(await client.nextUpdate())
    #expect(update.update == RFBUpdate(rectangles: [], resized: true))
    #expect(update.width == 30 && update.height == 20)
    #expect(server.framebuffer.width == 30 && server.framebuffer.height == 20)
  }

  // MARK: Events and raw bytes

  @Test func bellAndCutTextReachTheClient() async throws {
    let server = try await open()
    defer { server.stop() }
    let client = try await Client(to: server)
    defer { client.close() }
    _ = await client.nextUpdate()
    server.sendBell()
    server.sendCutText("héllo\r\nworld")
    #expect(await client.nextEvent() == .bell)
    // Latin-1 on the wire, and CRLF normalised to LF on the way out.
    #expect(await client.nextEvent() == .serverCutText("héllo\nworld"))
  }

  /// `write` is the escape hatch for malformed-message tests: whatever bytes
  /// go in reach the client untouched.
  @Test func rawBytesAreForwardedVerbatim() async throws {
    let server = try await open()
    defer { server.stop() }
    let client = try await Client(to: server)
    defer { client.close() }
    _ = await client.nextUpdate()
    server.write([2, 2, 0xc8])  // two bells, then an unknown message type
    #expect(await client.nextEvent() == .bell)
    #expect(await client.nextEvent() == .bell)
    #expect(await client.run.value as? RFBError == .malformed("unknown server message 200"))
  }

  @Test func closingTheClientEndsItsRunButLeavesTheServerListening() async throws {
    let server = try await open()
    defer { server.stop() }
    let client = try await Client(to: server)
    _ = await client.nextUpdate()
    server.closeClient()
    #expect(await client.run.value as? RFBError == .connectionClosed)
    let replacement = try await Client(to: server)
    defer { replacement.close() }
    #expect(await replacement.nextUpdate() != nil)
  }
}

/// A lock-guarded sink for the server's message callback, which fires on the
/// server's own queue.
final class MessageBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [RFBClientMessage] = []
  var messages: [RFBClientMessage] { lock.withLock { storage } }
  func append(_ message: RFBClientMessage) { lock.withLock { storage.append(message) } }
}
