import Foundation
import Network
import ScreenSharing

/// The client's SetEncodings: in its order (preference) and as a set.
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

/// An in-process VNC server for tests, `vnc-bench` and the rig: a scripted
/// handshake, a BGRA framebuffer whose rectangles go out as Raw, CopyRect,
/// ZRLE or DesktopSize, deterministic scenes (`play`), an optional pointer
/// echo, and a log of every client message. One client at a time. Its own
/// target so product modules never link it.
///
/// It is the reference implementation VNC features are validated against
/// (docs/plans/vnc-validation.md): a feature adds its server side here in the
/// same change, and `implementedEncodings` must cover everything the client
/// advertises.
public final class RFBLoopbackServer: @unchecked Sendable {
  /// Every encoding and pseudo-encoding this server can send.
  public static let implementedEncodings: Set<RFBEncoding> = [
    .raw, .copyRect, .tight, .zrle, .desktopSize, .cursor, .pointerPosition, .fence, .continuousUpdates,
    .extendedDesktopSize, .extendedClipboard,
  ]

  public struct Configuration: Sendable {
    public var version = RFBProtocolVersion.v3_8
    public var securityTypes: [UInt8] = [RFBSecurityType.vncAuthentication.rawValue]
    public var password: String? = "secret"
    public var width = 64
    public var height = 48
    public var name = "Loopback"
    /// The encoding of a whole-frame reply and of `.encoded` rectangles.
    public var encoding: RFBEncoding = .raw
    /// Use the client's first preference among Tight, ZRLE and Raw instead of
    /// `encoding` (and JPEG only when it asked for a Tight quality level), as a
    /// real server does. Off by default: tests pin `encoding`.
    public var negotiateEncoding = false
    /// nil: an ephemeral port, read from `port` once started.
    public var port: UInt16?
    /// Answer every pointer event with an `echoMarker` at the pointer, so
    /// input-to-update latency is measurable in one process.
    public var echoPointer = false
    /// Sent with the first update to a client that advertises the Cursor pseudo-encoding.
    public var cursor: RFBCursorShape?
    /// Confirm ContinuousUpdates to clients that advertise it. Off by default, like a
    /// basic server: request/response tests synchronise on `isRequestPending`.
    public var continuousUpdates = false
    /// Speak Fence: request one from clients that advertise it, and answer theirs. Off by default.
    public var fences = false
    /// ExtendedDesktopSize: announce the layout to clients that advertise it and
    /// accept (or refuse) their SetDesktopSize. Unsupported by default.
    public var desktopResize: DesktopResize = .unsupported
    /// Extended Clipboard (UTF-8): offer caps to clients that advertise it,
    /// request text they announce, provide ours on request. Off by default.
    public var extendedClipboard = false
    public enum DesktopResize: Sendable { case unsupported, accept, refuse }
    public init() {}
  }

  public enum Rectangle: Sendable {
    case raw(RFBRectangle)
    case zrle(RFBRectangle)
    /// Pixels in the server's encoding: the negotiated one, else `Configuration.encoding`.
    case encoded(RFBRectangle)
    case copy(RFBRectangle, fromX: Int, fromY: Int)
    /// CopyRect whose move the framebuffer already holds (scenes apply their changes in order).
    case moved(RFBRectangle, fromX: Int, fromY: Int)
    /// Cursor pseudo-encoding: the pointer's shape.
    case cursor(RFBCursorShape)
    /// PointerPos pseudo-encoding: the server moved the pointer.
    case pointer(RFBPoint)
    /// ExtendedDesktopSize: the layout, or the answer to a SetDesktopSize (a
    /// successful one has already resized the framebuffer).
    case extendedDesktopSize(RFBDesktopSizeResult)
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
  var deflater: RFBZlibDeflater?
  /// Per connection: its zlib streams must start over with each client's (a reconnect otherwise desyncs them).
  var tightEncoder = RFBTightEncoder()
  /// The Tight quality level the client asked for (-32…-23), if any.
  var clientQualityLevel: Int? {
    clientEncodings.compactMap { (-32 ... -23).contains($0) ? Int($0 + 32) : nil }.max()
  }
  /// The encoding pixels go out in.
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
  /// The payload of the fence request this server sends a Fence-capable client.
  public static let fenceProbe: [UInt8] = [0xC0, 0xDE]
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
  /// A change sent now reaches the client: it has a request pending, or continuous updates are on.
  public var wantsUpdate: Bool { lock.withLock { pendingRequest || continuous } }
  /// The client turned continuous updates on and hasn't turned them off.
  public var isContinuous: Bool { lock.withLock { continuous } }
  /// Text the client provided over the Extended Clipboard, in order.
  public var clipboardTextsReceived: [String] { lock.withLock { providedTexts } }
  /// Every fence the client sent: replies to this server's requests, and its own requests.
  public var fencesReceived: [(flags: UInt32, payload: [UInt8])] { lock.withLock { fenceLog } }

  // MARK: Driving the client

  /// Sends now if the client is waiting for an update, otherwise on its next request.
  public func enqueue(_ rectangles: [Rectangle]) {
    lock.withLock {
      pending.append(contentsOf: rectangles)
      if pendingRequest || continuous { flushPendingLocked() }
    }
  }

  public func paint(_ rect: RFBRectangle, blue: UInt8, green: UInt8, red: UInt8) throws {
    try lock.withLock { try framebuffer.fill(rect, blue: blue, green: green, red: red) }
  }

  /// `pixels`: `rect.width * rect.height` BGRA pixels, row-major.
  public func paint(_ rect: RFBRectangle, pixels: [UInt8]) throws {
    try lock.withLock { try framebuffer.fillRaw(rect, from: pixels) }
  }

  /// Applies the scene's next frame and sends it like `enqueue`; an idle
  /// frame sends nothing. Returns false, leaving the scene where it was, while
  /// the previous frame is still waiting for the client's request: pixels are
  /// encoded when sent, so a second frame on top of an unsent one (a scroll
  /// after a scroll) would reach the client out of step with the server.
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

  // MARK: Pointer echo

  public static let echoMarkerSize = 4
  private static let echoTag: UInt8 = 0xE3

  /// The marker colour for the `sequence`th echoed pointer event (1-based, modulo 65536).
  public static func echoMarker(sequence: Int) -> (blue: UInt8, green: UInt8, red: UInt8) {
    (UInt8(truncatingIfNeeded: sequence), UInt8(truncatingIfNeeded: sequence >> 8), echoTag)
  }

  /// The sequence a pixel's colour marks, or nil when it is not a marker.
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

  /// The encodings the client advertised in its last SetEncodings.
  public var advertisedEncodings: Set<Int32> { lock.withLock { Set(clientEncodings.orderedOriginal) } }

  /// Ends continuous updates from the server side (EndOfContinuousUpdates); the client falls back to requests.
  public func endContinuousUpdates() {
    lock.withLock {
      guard continuous else { return }
      continuous = false
      client?.send(content: Data([150]), completion: .idempotent)
    }
  }

  /// Sends a cursor shape, if the client advertised the Cursor pseudo-encoding.
  public func setCursor(_ shape: RFBCursorShape) {
    lock.withLock {
      guard clientEncodings.contains(RFBEncoding.cursor.rawValue) else { return }
      pending.append(.cursor(shape))
      if pendingRequest || continuous { flushPendingLocked() }
    }
  }

  /// Moves the pointer server-side, if the client advertised PointerPos.
  public func movePointer(to point: RFBPoint) {
    lock.withLock {
      guard clientEncodings.contains(RFBEncoding.pointerPosition.rawValue) else { return }
      pending.append(.pointer(point))
      if pendingRequest || continuous { flushPendingLocked() }
    }
  }

  public func sendBell() { write([2]) }

  /// Sets the server's clipboard: announced over the Extended Clipboard to a
  /// client that negotiated it (and provided when it asks), else sent as Latin-1.
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
        if case .setEncodings(let encodings) = message {
          clientEncodings = OrderedEncodings(encodings)
          if configuration.continuousUpdates, clientEncodings.contains(RFBEncoding.continuousUpdates.rawValue) {
            client?.send(content: Data([150]), completion: .idempotent)  // EndOfContinuousUpdates: supported
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
            client?.send(content: Data([150]), completion: .idempotent)  // EndOfContinuousUpdates: stopped
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
            // A full request always gets the whole frame, after anything already queued.
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
      // Eager, unlike TigerVNC (which asks only when something pastes): tests see the text at once.
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

  /// SetDesktopSize: resize and repaint (black, then whatever is painted next), or refuse.
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
