import Foundation

public actor RFBClient {
  public nonisolated let framebuffer: RFBFramebuffer
  private let transport: any RFBTransport
  public nonisolated var controlChannel: (any RFBControlChannel)? { transport as? any RFBControlChannel }
  private let stream: RFBInputStream
  private var inflater: RFBZlibInflater?
  private let tight = RFBTightDecoder()
  public private(set) var qualityLevel: Int?
  private var closed = false
  private let now: @Sendable () -> ContinuousClock.Instant
  private var requestsSentAt: [ContinuousClock.Instant] = []
  public var requestDepth = 1
  public var requestsBeforeApplying = false
  public func setRequestPipelining(depth: Int, beforeApplying: Bool) {
    requestDepth = max(1, depth)
    requestsBeforeApplying = beforeApplying
  }
  private var continuous = false
  private var continuousConfirmed = false
  private var serverFences = false
  private var pingToken: UInt32 = 0
  private var pingSentAt: ContinuousClock.Instant?
  private var lastPingAt: ContinuousClock.Instant?
  static let pingInterval: Duration = .seconds(1)

  public init(
    transport: any RFBTransport, framebuffer: RFBFramebuffer? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
    qualityLevel: Int? = nil
  ) throws {
    self.transport = transport
    self.qualityLevel = qualityLevel.map { min(max($0, 0), 9) }
    self.now = now
    stream = RFBInputStream(transport: transport)
    self.framebuffer = try framebuffer ?? RFBFramebuffer(width: 1, height: 1)
  }

  @discardableResult
  public func connect(
    password: String?, username: String? = nil, shared: Bool = true
  ) async throws
    -> RFBHandshake.Outcome
  {
    let outcome = try await RFBHandshake.perform(
      stream: stream, transport: transport, password: password, username: username, shared: shared)
    try framebuffer.resize(width: outcome.parameters.width, height: outcome.parameters.height)
    try await transport.write(
      RFBClientMessage.setPixelFormat(.bgra32).encoded + RFBClientMessage.setEncodings(encodings).encoded)
    return outcome
  }

  private var encodings: [Int32] {
    advertisedEncodings ?? RFBEncoding.supported.map(\.rawValue) + (qualityLevel.map { [Int32(-32 + $0)] } ?? [])
  }
  public var advertisedEncodings: [Int32]?
  public func advertise(_ encodings: [Int32]?) { advertisedEncodings = encodings }

  public func setQualityLevel(_ level: Int?) async throws {
    let clamped = level.map { min(max($0, 0), 9) }
    guard clamped != qualityLevel else { return }
    qualityLevel = clamped
    try await send(.setEncodings(encodings))
  }

  public func send(_ message: RFBClientMessage) async throws {
    guard !closed else { throw RFBError.connectionClosed }
    try await transport.write(message.encoded)
  }

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
        let answered = requestsSentAt.isEmpty ? nil : requestsSentAt.removeFirst()
        if !continuous, requestsBeforeApplying { try await topUpRequests() }
        let started = ContinuousClock.now
        stream.startTiming()
        var update = try await readFramebufferUpdate()
        update.transferDuration = started.duration(to: .now)
        let link = stream.stopTiming()
        update.linkBytes = link.bytes
        update.linkDuration = link.duration
        update.byteCount = stream.consumed - start
        if let answered { update.latency = answered.duration(to: now()) }
        onUpdate(framebuffer, update)
        if !continuous {
          if !requestsBeforeApplying { try await topUpRequests() }
        } else if update.resized {
          try await send(.enableContinuousUpdates(enable: true, fullFrame))
        }
        try await pingIfDue()
      case 150:
        if !continuousConfirmed {
          continuousConfirmed = true
          continuous = true
          try await send(.enableContinuousUpdates(enable: true, fullFrame))
          onEvent(.continuousUpdates(true))
        } else if continuous {
          continuous = false
          onEvent(.continuousUpdates(false))
          try await request(incremental: true)
        }
      case 248:
        let (flags, payload) = try await RFBFence.read(from: stream)
        serverFences = true
        if flags & RFBFence.request != 0 {
          try await send(.fence(flags: flags & RFBFence.understood, payload: payload))
        } else if let sent = pingSentAt, payload == pingPayload {
          pingSentAt = nil
          onEvent(.roundTrip(sent.duration(to: now())))
        }
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
          let size = Int(-Int64(length))
          guard size <= RFBExtendedClipboard.maximumBytes else {
            throw RFBError.malformed("extended clipboard message of \(size) bytes")
          }
          if let message = try? RFBExtendedClipboard.decode(try await stream.bytes(size)) {
            onEvent(.extendedClipboard(message))
          }
        }
      case let type:
        throw RFBError.malformed("unknown server message \(type)")
      }
    }
  }

  public nonisolated func close() { transport.close() }

  public nonisolated var transportName: String { transport.name }

  private var pingPayload: [UInt8] {
    [
      UInt8(pingToken >> 24 & 0xFF), UInt8(pingToken >> 16 & 0xFF), UInt8(pingToken >> 8 & 0xFF),
      UInt8(pingToken & 0xFF),
    ]
  }

  private func pingIfDue() async throws {
    guard serverFences, pingSentAt == nil else { return }
    let current = now()
    if let lastPingAt, lastPingAt.duration(to: current) < Self.pingInterval { return }
    pingToken &+= 1
    pingSentAt = current
    lastPingAt = current
    try await send(.fence(flags: RFBFence.request, payload: pingPayload))
  }

  private func request(incremental: Bool) async throws {
    requestsSentAt.append(now())
    try await send(.framebufferUpdateRequest(incremental: incremental, fullFrame))
  }

  private func topUpRequests() async throws {
    while requestsSentAt.count < requestDepth { try await request(incremental: true) }
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
    var desktopSize: RFBDesktopSizeResult?
    var jpegRectangles = 0
    var encodingCounts: [Int32: Int] = [:]
    for _ in 0..<count {
      let x = Int(try await stream.u16()), y = Int(try await stream.u16())
      let width = Int(try await stream.u16()), height = Int(try await stream.u16())
      let rect = RFBRectangle(x: x, y: y, width: width, height: height)
      let encoding = try await stream.s32()
      encodingCounts[encoding, default: 0] += 1
      switch RFBEncoding(rawValue: encoding) {
      case .raw:
        try framebuffer.validate(rect)
        try framebuffer.fillRaw(rect, from: try await stream.bytes(width * height * 4))
        rectangles.append(rect)
      case .tight:
        try await tight.decode(rect, from: stream, into: framebuffer)
        if tight.lastKind == "jpeg" { jpegRectangles += 1 }
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
        guard width <= RFBCursorShape.maximumDimension, height <= RFBCursorShape.maximumDimension else {
          throw RFBError.malformed("cursor \(width) × \(height)")
        }
        let payload = try await stream.bytes(
          width * height * 4 + RFBCursorShape.maskLength(width: width, height: height))
        cursor = try RFBCursorShape.decode(width: width, height: height, hotspotX: x, hotspotY: y, payload: payload)
      case .pointerPosition:
        pointer = RFBPoint(x: x, y: y)
      case .extendedDesktopSize:
        let count = Int(try await stream.u8())
        try await stream.skip(3)
        let screens = try await RFBScreenLayout.read(count, from: stream)
        guard let reason = RFBDesktopSizeResult.Reason(rawValue: x) else {
          throw RFBError.malformed("ExtendedDesktopSize reason \(x)")
        }
        let status = RFBDesktopSizeResult.Status(rawValue: y) ?? .invalidLayout
        if status == .ok, width != framebuffer.width || height != framebuffer.height {
          try framebuffer.resize(width: width, height: height)
          resized = true
        }
        desktopSize = RFBDesktopSizeResult(
          reason: reason, status: status, width: width, height: height, screens: screens)
      case .fence, .continuousUpdates, .extendedClipboard, nil:
        throw RFBError.unsupportedEncoding(encoding)
      }
    }
    var update = RFBUpdate(rectangles: rectangles, resized: resized)
    update.cursor = cursor
    update.pointer = pointer
    update.desktopSize = desktopSize
    update.jpegRectangles = jpegRectangles
    update.encodingCounts = encodingCounts
    return update
  }
}
