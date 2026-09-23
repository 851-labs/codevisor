import Foundation

/// One RFB connection: `connect` negotiates and configures the framebuffer,
/// `run` reads server messages until the peer closes or a message is
/// invalid, keeping exactly one incremental update request in flight, and
/// `send` carries input and clipboard from any task. Reentrant at its
/// awaits, so input flows while a large update is being read.
public actor RFBClient {
  public nonisolated let framebuffer: RFBFramebuffer
  private let transport: any RFBTransport
  private let stream: RFBInputStream
  private var inflater: RFBZlibInflater?
  private var closed = false
  private let now: @Sendable () -> ContinuousClock.Instant
  private var requestSentAt: ContinuousClock.Instant?

  /// `now` times each update against its request; tests script it.
  public init(
    transport: any RFBTransport, framebuffer: RFBFramebuffer? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) throws {
    self.transport = transport
    self.now = now
    stream = RFBInputStream(transport: transport)
    self.framebuffer = try framebuffer ?? RFBFramebuffer(width: 1, height: 1)
  }

  /// Handshake, then SetPixelFormat and SetEncodings; the framebuffer takes the server's size.
  @discardableResult
  public func connect(password: String?, shared: Bool = true) async throws -> RFBHandshake.Outcome {
    let outcome = try await RFBHandshake.perform(
      stream: stream, transport: transport, password: password, shared: shared)
    try framebuffer.resize(width: outcome.parameters.width, height: outcome.parameters.height)
    try await transport.write(
      RFBClientMessage.setPixelFormat(.bgra32).encoded
        + RFBClientMessage.setEncodings(RFBEncoding.supported.map(\.rawValue)).encoded)
    return outcome
  }

  public func send(_ message: RFBClientMessage) async throws {
    guard !closed else { throw RFBError.connectionClosed }
    try await transport.write(message.encoded)
  }

  /// Requests the whole framebuffer, then applies updates as they arrive.
  /// `onUpdate` runs on the actor after each update; the framebuffer is stable
  /// for its duration. Returns only by throwing: `RFBError.connectionClosed`
  /// after a clean close, or the failure that ended the session.
  public func run(
    onUpdate: @Sendable (RFBFramebuffer, RFBUpdate) -> Void, onEvent: @Sendable (RFBServerEvent) -> Void
  ) async throws -> Never {
    defer {
      closed = true
      transport.close()
    }
    try await request(incremental: false)
    while true {
      try Task.checkCancellation()
      let start = stream.consumed
      switch try await stream.u8() {
      case 0:
        var update = try await readFramebufferUpdate()
        update.byteCount = stream.consumed - start
        if let requestSentAt { update.latency = requestSentAt.duration(to: now()) }
        onUpdate(framebuffer, update)
        try await request(incremental: true)
      case 1:
        try await stream.skip(3)
        try await stream.skip(Int(try await stream.u16()) * 6)
      case 2:
        onEvent(.bell)
      case 3:
        try await stream.skip(3)
        let length = try await stream.s32()
        if length >= 0 {
          onEvent(.serverCutText(RFBLatin1.decode(try await stream.bytes(Int(length)))))
        } else {
          try await stream.skip(Int(-Int64(length)))  // extended clipboard we never asked for
        }
      case let type:
        throw RFBError.malformed("unknown server message \(type)")
      }
    }
  }

  public nonisolated func close() { transport.close() }

  /// What carries the connection ("TCP", "WebSocket"), for diagnostics.
  public nonisolated var transportName: String { transport.name }

  private func request(incremental: Bool) async throws {
    requestSentAt = now()
    try await send(.framebufferUpdateRequest(incremental: incremental, fullFrame))
  }

  private var fullFrame: RFBRectangle {
    RFBRectangle(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
  }

  private func readFramebufferUpdate() async throws -> RFBUpdate {
    try await stream.skip(1)
    let count = Int(try await stream.u16())
    var rectangles: [RFBRectangle] = []
    var resized = false
    var cursor: RFBCursorShape?
    var pointer: RFBPoint?
    for _ in 0..<count {
      let x = Int(try await stream.u16()), y = Int(try await stream.u16())
      let width = Int(try await stream.u16()), height = Int(try await stream.u16())
      let rect = RFBRectangle(x: x, y: y, width: width, height: height)
      let encoding = try await stream.s32()
      switch RFBEncoding(rawValue: encoding) {
      case .raw:
        try framebuffer.validate(rect)
        try framebuffer.fillRaw(rect, from: try await stream.bytes(width * height * 4))
        rectangles.append(rect)
      case .copyRect:
        let fromX = Int(try await stream.u16()), fromY = Int(try await stream.u16())
        try framebuffer.copy(rect, fromX: fromX, fromY: fromY)
        rectangles.append(rect)
      case .zrle:
        let length = Int(try await stream.u32())
        guard length <= 64 << 20 else { throw RFBError.malformed("ZRLE rectangle of \(length) bytes") }
        let compressed = try await stream.bytes(length)
        if inflater == nil { inflater = try RFBZlibInflater() }
        try RFBZRLEDecoder.decode(try inflater!.inflate(compressed), rect: rect, into: framebuffer)
        rectangles.append(rect)
      case .desktopSize:
        try framebuffer.resize(width: width, height: height)
        resized = true
      case .cursor:
        // x and y are the hotspot; the payload is sized before it is read.
        guard width <= RFBCursorShape.maximumDimension, height <= RFBCursorShape.maximumDimension else {
          throw RFBError.malformed("cursor \(width) × \(height)")
        }
        let payload = try await stream.bytes(
          width * height * 4 + RFBCursorShape.maskLength(width: width, height: height))
        cursor = try RFBCursorShape.decode(width: width, height: height, hotspotX: x, hotspotY: y, payload: payload)
      case .pointerPosition:
        pointer = RFBPoint(x: x, y: y)
      case nil:
        throw RFBError.unsupportedEncoding(encoding)
      }
    }
    var update = RFBUpdate(rectangles: rectangles, resized: resized)
    update.cursor = cursor
    update.pointer = pointer
    return update
  }
}
