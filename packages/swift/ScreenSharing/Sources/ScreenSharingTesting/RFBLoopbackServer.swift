import Foundation
import Network
import ScreenSharing

struct OrderedEncodings {
  let orderedOriginal: [Int32]
  private let members: Set<Int32>
  init(_ encodings: [Int32] = []) {
    orderedOriginal = encodings
    members = Set(encodings)
  }
  func contains(_ value: Int32) -> Bool { members.contains(value) }
  func compactMap<T>(_ transform: (Int32) -> T?) -> [T] { orderedOriginal.compactMap(transform) }
}

public final class RFBLoopbackServer: @unchecked Sendable {
  public static let implementedEncodings: Set<RFBEncoding> = [
    .raw, .copyRect, .tight, .zrle, .desktopSize, .cursor, .pointerPosition, .fence, .continuousUpdates,
    .extendedDesktopSize, .extendedClipboard,
  ]

  public struct Configuration: Sendable {
    public var version = RFBProtocolVersion.v3_8
    public var securityTypes: [UInt8] = [RFBSecurityType.vncAuthentication.rawValue]
    public var account: (username: String, password: String)?
    public var password: String? = "secret"
    public var width = 64
    public var height = 48
    public var name = "Loopback"
    public var encoding: RFBEncoding = .raw
    public var negotiateEncoding = false
    public var port: UInt16?
    public var echoPointer = false
    public var cursor: RFBCursorShape?
    public var continuousUpdates = false
    public var fences = false
    public var desktopResize: DesktopResize = .unsupported
    public var extendedClipboard = false
    public enum DesktopResize: Sendable { case unsupported, accept, refuse }
    public init() {}
  }

  public enum Rectangle: Sendable {
    case raw(RFBRectangle)
    case zrle(RFBRectangle)
    case encoded(RFBRectangle)
    case copy(RFBRectangle, fromX: Int, fromY: Int)
    case moved(RFBRectangle, fromX: Int, fromY: Int)
    case cursor(RFBCursorShape)
    case pointer(RFBPoint)
    case extendedDesktopSize(RFBDesktopSizeResult)
    case desktopSize(width: Int, height: Int)
  }

  public private(set) var port: UInt16 = 0
  public let framebuffer: RFBFramebuffer
  let configuration: Configuration
  private let listener: NWListener
  private let queue = DispatchQueue(label: "com.851labs.Codevisor.rfb.loopback")
  private let lock = NSLock()
  private var client: NWConnection?
  private var transport: RFBNetworkTransport?
  private var serving: Task<Void, Never>?
  private var pendingRequest = false
  private var pending: [Rectangle] = []
  private var messages: [RFBClientMessage] = []
  var deflater: RFBZlibDeflater?
  var tightEncoder = RFBTightEncoder()
  var clientQualityLevel: Int? {
    clientEncodings.compactMap { (-32 ... -23).contains($0) ? Int($0 + 32) : nil }.max()
  }
  var pixelEncoding: RFBEncoding {
    guard configuration.negotiateEncoding else { return configuration.encoding }
    let offered: [RFBEncoding] = [.tight, .zrle, .raw]
    for value in clientEncodings.orderedOriginal {
      if let encoding = RFBEncoding(rawValue: value), offered.contains(encoding) { return encoding }
    }
    return configuration.encoding
  }
  private var connections = 0
  private var echoes = 0
  private var sceneFrameUnsent = false
  private var clientEncodings = OrderedEncodings()
  private var continuous = false
  private var clientClipboardCaps = false
  private var serverClipboard: String?
  private var providedTexts: [String] = []
  private var fenceLog: [(flags: UInt32, payload: [UInt8])] = []
  public static let fenceProbe: [UInt8] = [0xC0, 0xDE]
  public var onClientMessage: (@Sendable (RFBClientMessage) -> Void)?

  public init(configuration: Configuration = .init()) async throws {
    self.configuration = configuration
    framebuffer = try RFBFramebuffer(width: configuration.width, height: configuration.height)
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: .ipv4(.loopback), port: configuration.port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
    listener = try NWListener(using: parameters)
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

  public var received: [RFBClientMessage] { lock.withLock { messages } }
  public var connectionCount: Int { lock.withLock { connections } }
  public var isRequestPending: Bool { lock.withLock { pendingRequest } }
  public var wantsUpdate: Bool { lock.withLock { pendingRequest || continuous } }
  public var isContinuous: Bool { lock.withLock { continuous } }
  public var clipboardTextsReceived: [String] { lock.withLock { providedTexts } }
  public var fencesReceived: [(flags: UInt32, payload: [UInt8])] { lock.withLock { fenceLog } }

  public func enqueue(_ rectangles: [Rectangle]) {
    lock.withLock {
      pending.append(contentsOf: rectangles)
      if pendingRequest || continuous { flushPendingLocked() }
    }
  }

  public func paint(_ rect: RFBRectangle, blue: UInt8, green: UInt8, red: UInt8) throws {
    try lock.withLock { try framebuffer.fill(rect, blue: blue, green: green, red: red) }
  }

  public func paint(_ rect: RFBRectangle, pixels: [UInt8]) throws {
    try lock.withLock { try framebuffer.fillRaw(rect, from: pixels) }
  }

  @discardableResult
  public func play(_ scene: inout RFBLoopbackScene) throws -> Bool {
    try lock.withLock {
      guard !sceneFrameUnsent else { return false }
      let rectangles = try scene.next(on: framebuffer)
      guard !rectangles.isEmpty else { return true }
      pending.append(contentsOf: rectangles)
      sceneFrameUnsent = true
      if pendingRequest || continuous { flushPendingLocked() }
      return true
    }
  }

  public static let echoMarkerSize = 4
  private static let echoTag: UInt8 = 0xE3

  public static func echoMarker(sequence: Int) -> (blue: UInt8, green: UInt8, red: UInt8) {
    (UInt8(truncatingIfNeeded: sequence), UInt8(truncatingIfNeeded: sequence >> 8), echoTag)
  }

  public static func echoSequence(blue: UInt8, green: UInt8, red: UInt8) -> Int? {
    red == echoTag ? Int(blue) | Int(green) << 8 : nil
  }

  private func echoLocked(x: Int, y: Int) {
    echoes += 1
    let size = Self.echoMarkerSize
    let rect = RFBRectangle(
      x: min(max(0, x), max(0, framebuffer.width - size)), y: min(max(0, y), max(0, framebuffer.height - size)),
      width: min(size, framebuffer.width), height: min(size, framebuffer.height))
    let marker = Self.echoMarker(sequence: echoes)
    guard (try? framebuffer.fill(rect, blue: marker.blue, green: marker.green, red: marker.red)) != nil else { return }
    pending.append(.raw(rect))
    if pendingRequest || continuous { flushPendingLocked() }
  }

  public var advertisedEncodings: Set<Int32> { lock.withLock { Set(clientEncodings.orderedOriginal) } }

  public func endContinuousUpdates() {
    lock.withLock {
      guard continuous else { return }
      continuous = false
      client?.send(content: Data([150]), completion: .idempotent)
    }
  }

  public func setCursor(_ shape: RFBCursorShape) {
    lock.withLock {
      guard clientEncodings.contains(RFBEncoding.cursor.rawValue) else { return }
      pending.append(.cursor(shape))
      if pendingRequest || continuous { flushPendingLocked() }
    }
  }

  public func movePointer(to point: RFBPoint) {
    lock.withLock {
      guard clientEncodings.contains(RFBEncoding.pointerPosition.rawValue) else { return }
      pending.append(.pointer(point))
      if pendingRequest || continuous { flushPendingLocked() }
    }
  }

  public func sendBell() { write([2]) }

  public func setClipboard(_ text: String) {
    let extended = lock.withLock { () -> Bool in
      serverClipboard = text
      return clientClipboardCaps
    }
    if extended {
      writeExtendedClipboard(.notify(formats: RFBExtendedClipboard.text))
    } else {
      sendCutText(text)
    }
  }

  func writeExtendedClipboard(_ message: RFBExtendedClipboard.Message) {
    guard let payload = try? RFBExtendedClipboard.encode(message) else { return }
    var writer = RFBByteWriter()
    writer.u8(3); writer.pad(3); writer.s32(-Int32(payload.count)); writer.append(payload)
    write(writer.bytes)
  }

  public func sendCutText(_ text: String) {
    var writer = RFBByteWriter()
    let latin1 = RFBLatin1.encode(text)
    writer.u8(3); writer.pad(3); writer.u32(UInt32(latin1.count)); writer.append(latin1)
    write(writer.bytes)
  }

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

  private func accept(_ connection: NWConnection) {
    let transport = RFBNetworkTransport(connection: connection)
    lock.withLock {
      client?.cancel()
      client = connection
      self.transport = transport
      connections += 1
      pendingRequest = false
      continuous = false
      deflater = nil
      tightEncoder = RFBTightEncoder()
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
    case RFBSecurityType.appleRemoteDesktop.rawValue:
      guard try await authenticateAppleAccount(stream: stream, transport: transport, version: version) else { return }
    default:
      return
    }
    _ = try await stream.u8()
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
        if case .setEncodings(let encodings) = message {
          clientEncodings = OrderedEncodings(encodings)
          if configuration.continuousUpdates, clientEncodings.contains(RFBEncoding.continuousUpdates.rawValue) {
            client?.send(content: Data([150]), completion: .idempotent)
          }
          if configuration.fences, clientEncodings.contains(RFBEncoding.fence.rawValue) {
            client?.send(
              content: Data(Self.fenceBytes(flags: RFBFence.request | RFBFence.blockBefore, payload: Self.fenceProbe)),
              completion: .idempotent)
          }
          if let cursor = configuration.cursor, clientEncodings.contains(RFBEncoding.cursor.rawValue) {
            pending.append(.cursor(cursor))
          }
          if configuration.extendedClipboard, clientEncodings.contains(RFBExtendedClipboard.pseudoEncoding),
            let caps = try? RFBExtendedClipboard.encode(
              .caps(
                formats: RFBExtendedClipboard.text,
                actions: RFBExtendedClipboard.request | RFBExtendedClipboard.peek | RFBExtendedClipboard.notify
                  | RFBExtendedClipboard.provide,
                maximumSizes: [UInt32(RFBExtendedClipboard.maximumBytes)]))
          {
            var writer = RFBByteWriter()
            writer.u8(3); writer.pad(3); writer.s32(-Int32(caps.count)); writer.append(caps)
            client?.send(content: Data(writer.bytes), completion: .idempotent)
          }
          if configuration.desktopResize != .unsupported,
            clientEncodings.contains(RFBEncoding.extendedDesktopSize.rawValue)
          {
            pending.append(.extendedDesktopSize(layoutLocked(reason: .server, status: .ok)))
          }
        }
        if case .enableContinuousUpdates(let enable, _) = message, configuration.continuousUpdates {
          continuous = enable
          if enable {
            if !pending.isEmpty { flushPendingLocked() }
          } else {
            client?.send(content: Data([150]), completion: .idempotent)
          }
        }
        if case .extendedClipboard(let clipboard) = message { extendedClipboardLocked(clipboard) }
        if case .setDesktopSize(let width, let height, _) = message {
          resizeRequestedLocked(width: width, height: height)
        }
        if case .fence(let flags, let payload) = message {
          fenceLog.append((flags, payload))
          if flags & RFBFence.request != 0, configuration.fences {
            client?.send(
              content: Data(Self.fenceBytes(flags: flags & RFBFence.understood, payload: payload)),
              completion: .idempotent)
          }
        }
        if configuration.echoPointer, case .pointerEvent(_, let x, let y) = message {
          echoLocked(x: Int(x), y: Int(y))
        }
        if case .framebufferUpdateRequest(let incremental, _) = message {
          if !incremental {
            let full = RFBRectangle(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
            pending.append(.encoded(full))
            flushPendingLocked()
          } else if !pending.isEmpty {
            flushPendingLocked()
          } else {
            pendingRequest = true
          }
        }
      }
    }
  }

  private func extendedClipboardLocked(_ message: RFBExtendedClipboard.Message) {
    guard configuration.extendedClipboard else { return }
    func send(_ reply: RFBExtendedClipboard.Message) {
      guard let payload = try? RFBExtendedClipboard.encode(reply) else { return }
      var writer = RFBByteWriter()
      writer.u8(3); writer.pad(3); writer.s32(-Int32(payload.count)); writer.append(payload)
      client?.send(content: Data(writer.bytes), completion: .idempotent)
    }
    switch message {
    case .caps(let formats, _, _): clientClipboardCaps = formats & RFBExtendedClipboard.text != 0
    case .notify(let formats):
      if formats & RFBExtendedClipboard.text != 0 { send(.request(formats: RFBExtendedClipboard.text)) }
    case .request: send(.provide(text: serverClipboard))
    case .peek: send(.notify(formats: serverClipboard == nil ? 0 : RFBExtendedClipboard.text))
    case .provide(let text): if let text { providedTexts.append(text) }
    }
  }

  private func layoutLocked(
    reason: RFBDesktopSizeResult.Reason, status: RFBDesktopSizeResult.Status
  )
    -> RFBDesktopSizeResult
  {
    RFBDesktopSizeResult(
      reason: reason, status: status, width: framebuffer.width, height: framebuffer.height,
      screens: [RFBScreen(id: 1, x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)])
  }

  private func resizeRequestedLocked(width: Int, height: Int) {
    guard configuration.desktopResize != .unsupported else { return }
    let accepted =
      configuration.desktopResize == .accept && (1...RFBFramebuffer.maximumDimension).contains(width)
      && (1...RFBFramebuffer.maximumDimension).contains(height)
      && (try? framebuffer.resize(width: width, height: height)) != nil
    pending.append(.extendedDesktopSize(layoutLocked(reason: .thisClient, status: accepted ? .ok : .prohibited)))
    if accepted {
      let full = RFBRectangle(x: 0, y: 0, width: width, height: height)
      pending.append(.encoded(full))
    }
    if pendingRequest || continuous { flushPendingLocked() }
  }

  static func fenceBytes(flags: UInt32, payload: [UInt8]) -> [UInt8] {
    var writer = RFBByteWriter()
    writer.u8(248); writer.pad(3); writer.u32(flags); writer.u8(UInt8(payload.count)); writer.append(payload)
    return writer.bytes
  }

  private func flushPendingLocked() {
    let rectangles = pending
    pending = []
    pendingRequest = false
    sceneFrameUnsent = false
    guard let client, let bytes = try? encode(rectangles) else { return }
    client.send(content: Data(bytes), completion: .idempotent)
  }
}
