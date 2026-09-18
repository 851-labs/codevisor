import Foundation
import Network
import ScreenSharing

/// An in-process VNC server for tests and the rig: a scripted handshake, a
/// BGRA framebuffer whose rectangles go out as Raw, CopyRect, ZRLE or
/// DesktopSize, and a log of every client message. One client at a time.
/// Its own target so product modules never link it.
public final class RFBLoopbackServer: @unchecked Sendable {
  public struct Configuration: Sendable {
    public var version = RFBProtocolVersion.v3_8
    public var securityTypes: [UInt8] = [RFBSecurityType.vncAuthentication.rawValue]
    public var password: String? = "secret"
    public var width = 64
    public var height = 48
    public var name = "Loopback"
    /// The encoding of a whole-frame reply to a non-incremental request.
    public var encoding: RFBEncoding = .raw
    /// nil: an ephemeral port, read from `port` once started.
    public var port: UInt16?
    public init() {}
  }

  public enum Rectangle: Sendable {
    case raw(RFBRectangle)
    case zrle(RFBRectangle)
    case copy(RFBRectangle, fromX: Int, fromY: Int)
    case desktopSize(width: Int, height: Int)
  }

  public private(set) var port: UInt16 = 0
  public let framebuffer: RFBFramebuffer
  private let configuration: Configuration
  private let listener: NWListener
  private let queue = DispatchQueue(label: "com.851labs.Codevisor.rfb.loopback")
  private let lock = NSLock()
  private var client: NWConnection?
  private var transport: RFBNetworkTransport?
  private var serving: Task<Void, Never>?
  private var pendingRequest = false
  private var pending: [Rectangle] = []
  private var messages: [RFBClientMessage] = []
  private var deflater: RFBZlibDeflater?
  private var connections = 0
  /// Every client message as it arrives, for a live server's log.
  public var onClientMessage: (@Sendable (RFBClientMessage) -> Void)?

  public init(configuration: Configuration = .init()) async throws {
    self.configuration = configuration
    framebuffer = try RFBFramebuffer(width: configuration.width, height: configuration.height)
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: .ipv4(.loopback), port: configuration.port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
    listener = try NWListener(using: parameters)
    // A listener started without a connection handler fails with EINVAL.
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    port = try await withCheckedThrowingContinuation { continuation in
      let once = RFBOnce()
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready:
          if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
        case .failed(let error):
          if once.claim() { continuation.resume(throwing: RFBError.transport("listener failed: \(error)")) }
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  // MARK: Observation

  public var received: [RFBClientMessage] { lock.withLock { messages } }
  public var connectionCount: Int { lock.withLock { connections } }
  public var isRequestPending: Bool { lock.withLock { pendingRequest } }

  // MARK: Driving the client

  /// Sends now if the client is waiting for an update, otherwise on its next request.
  public func enqueue(_ rectangles: [Rectangle]) {
    lock.withLock {
      pending.append(contentsOf: rectangles)
      if pendingRequest { flushPendingLocked() }
    }
  }

  public func paint(_ rect: RFBRectangle, blue: UInt8, green: UInt8, red: UInt8) throws {
    try lock.withLock { try framebuffer.fill(rect, blue: blue, green: green, red: red) }
  }

  /// `pixels`: `rect.width * rect.height` BGRA pixels, row-major.
  public func paint(_ rect: RFBRectangle, pixels: [UInt8]) throws {
    try lock.withLock { try framebuffer.fillRaw(rect, from: pixels) }
  }

  public func sendBell() { write([2]) }

  public func sendCutText(_ text: String) {
    var writer = RFBByteWriter()
    let latin1 = RFBLatin1.encode(text)
    writer.u8(3); writer.pad(3); writer.u32(UInt32(latin1.count)); writer.append(latin1)
    write(writer.bytes)
  }

  /// Raw bytes, for malformed-message tests.
  public func write(_ bytes: [UInt8]) {
    lock.withLock { client?.send(content: Data(bytes), completion: .idempotent) }
  }

  public func closeClient() {
    lock.withLock {
      client?.cancel(); client = nil; transport = nil; pendingRequest = false
    }
  }

  public func stop() {
    closeClient()
    lock.withLock {
      serving?.cancel(); serving = nil
    }
    listener.cancel()
  }

  // MARK: Connection

  private func accept(_ connection: NWConnection) {
    let transport = RFBNetworkTransport(connection: connection)
    lock.withLock {
      client?.cancel()
      client = connection
      self.transport = transport
      connections += 1
      pendingRequest = false
      deflater = nil
      serving?.cancel()
      serving = Task { [weak self] in
        do {
          try await transport.waitUntilReady()
          try await self?.serve(transport)
        } catch {}
        connection.cancel()
      }
    }
  }

  private func serve(_ transport: RFBNetworkTransport) async throws {
    let stream = RFBInputStream(transport: transport)
    try await transport.write(configuration.version.encoded)
    guard let version = RFBProtocolVersion.parse(try await stream.bytes(12)) else { return }
    let chosen: UInt8
    if version == .v3_3 {
      chosen = configuration.securityTypes.first ?? 0
      try await transport.write([0, 0, 0, chosen])
    } else {
      try await transport.write([UInt8(configuration.securityTypes.count)] + configuration.securityTypes)
      chosen = try await stream.u8()
    }
    switch chosen {
    case RFBSecurityType.vncAuthentication.rawValue:
      let challenge = (0..<16).map { _ in UInt8.random(in: 0...255) }
      try await transport.write(challenge)
      let response = try await stream.bytes(16)
      let expected = RFBVNCAuthentication.response(challenge: challenge, password: configuration.password ?? "")
      if response != expected {
        let reason = Array("Authentication failed".utf8)
        try await transport.write([0, 0, 0, 1] + (version == .v3_8 ? [0, 0, 0, UInt8(reason.count)] + reason : []))
        return
      }
      try await transport.write([0, 0, 0, 0])
    case RFBSecurityType.none.rawValue:
      if version == .v3_8 { try await transport.write([0, 0, 0, 0]) }
    default:
      return
    }
    _ = try await stream.u8()  // ClientInit
    var writer = RFBByteWriter()
    writer.u16(UInt16(framebuffer.width)); writer.u16(UInt16(framebuffer.height))
    writer.append(RFBPixelFormat.bgra32.encoded)
    let name = Array(configuration.name.utf8)
    writer.u32(UInt32(name.count)); writer.append(name)
    try await transport.write(writer.bytes)
    while true {
      let message = try await RFBClientMessage.read(from: stream)
      onClientMessage?(message)
      lock.withLock {
        messages.append(message)
        if case .framebufferUpdateRequest(let incremental, _) = message {
          if !pending.isEmpty {
            flushPendingLocked()
          } else if !incremental {
            let full = RFBRectangle(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
            pending = [configuration.encoding == .zrle ? .zrle(full) : .raw(full)]
            flushPendingLocked()
          } else {
            pendingRequest = true
          }
        }
      }
    }
  }

  private func flushPendingLocked() {
    let rectangles = pending
    pending = []
    pendingRequest = false
    guard let client, let bytes = try? encode(rectangles) else { return }
    client.send(content: Data(bytes), completion: .idempotent)
  }

  private func encode(_ rectangles: [Rectangle]) throws -> [UInt8] {
    var writer = RFBByteWriter()
    writer.u8(0); writer.pad(1); writer.u16(UInt16(rectangles.count))
    for rectangle in rectangles {
      switch rectangle {
      case .raw(let rect):
        header(&writer, rect, .raw)
        writer.append(rows(rect))
      case .copy(let rect, let fromX, let fromY):
        header(&writer, rect, .copyRect)
        writer.u16(UInt16(fromX)); writer.u16(UInt16(fromY))
        try framebuffer.copy(rect, fromX: fromX, fromY: fromY)
      case .zrle(let rect):
        header(&writer, rect, .zrle)
        if deflater == nil { deflater = try RFBZlibDeflater() }
        let compressed = try deflater!.deflate(zrleTiles(rect))
        writer.u32(UInt32(compressed.count)); writer.append(compressed)
      case .desktopSize(let width, let height):
        header(&writer, RFBRectangle(x: 0, y: 0, width: width, height: height), .desktopSize)
        try framebuffer.resize(width: width, height: height)
      }
    }
    return writer.bytes
  }

  private func header(_ writer: inout RFBByteWriter, _ rect: RFBRectangle, _ encoding: RFBEncoding) {
    writer.u16(UInt16(rect.x)); writer.u16(UInt16(rect.y))
    writer.u16(UInt16(rect.width)); writer.u16(UInt16(rect.height))
    writer.s32(encoding.rawValue)
  }

  private func rows(_ rect: RFBRectangle) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(rect.width * rect.height * 4)
    for y in rect.y..<rect.maxY {
      let start = (y * framebuffer.width + rect.x) * 4
      bytes.append(contentsOf: framebuffer.pixels[start..<start + rect.width * 4])
    }
    return bytes
  }

  /// Solid tiles where the tile is one colour, raw tiles otherwise.
  private func zrleTiles(_ rect: RFBRectangle) -> [UInt8] {
    var bytes: [UInt8] = []
    var tileY = rect.y
    while tileY < rect.maxY {
      let tileHeight = min(RFBZRLEDecoder.tile, rect.maxY - tileY)
      var tileX = rect.x
      while tileX < rect.maxX {
        let tileWidth = min(RFBZRLEDecoder.tile, rect.maxX - tileX)
        var cpixels: [UInt8] = []
        cpixels.reserveCapacity(tileWidth * tileHeight * 3)
        for y in tileY..<tileY + tileHeight {
          for x in tileX..<tileX + tileWidth {
            let index = (y * framebuffer.width + x) * 4
            cpixels.append(contentsOf: framebuffer.pixels[index..<index + 3])
          }
        }
        let first = Array(cpixels.prefix(3))
        let solid = stride(from: 0, to: cpixels.count, by: 3).allSatisfy { Array(cpixels[$0..<$0 + 3]) == first }
        if solid {
          bytes.append(1); bytes.append(contentsOf: first)
        } else {
          bytes.append(0); bytes.append(contentsOf: cpixels)
        }
        tileX += RFBZRLEDecoder.tile
      }
      tileY += RFBZRLEDecoder.tile
    }
    return bytes
  }
}
