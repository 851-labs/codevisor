#if os(macOS)
  import Foundation

  @MainActor
  public final class VNCScreenSharingSession: ScreenSharingViewingSession {
    public let capabilities: ScreenSharingCapabilities = [.control, .clipboard]
    public let frames = ScreenSharingFrameMailbox()
    public let metrics: ScreenSharingMetrics
    public var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { emulator.controlChannel }
    public var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? {
      emulator.clipboardChannel
    }
    public private(set) var failure: String?
    public var onConnectionChanged: ((String) -> Void)?
    public var onCursorChanged: ((ScreenSharingCursorUpdate) -> Void)?
    public var videoShowsPointer: Bool { false }
    let client: RFBClient
    private let translator: VNCInputTranslator
    private let emulator: VNCHostEmulator
    private let publisher = VNCFramePublisher()
    private let transportName: String
    private let outbox: AsyncStream<RFBClientMessage>.Continuation
    private let sender: Task<Void, Never>
    private var run: Task<any Error, Never>!
    private let sleep: @Sendable (Duration) async throws -> Void
    private var resizeSupported = false
    private var resizeRefused = false
    private var firstUpdateSeen = false
    public var onResizeSupportChanged: ((Bool) -> Void)?
    private var screenID: UInt32 = 0
    private var desktopSize: (width: Int, height: Int)
    private var desiredSize: (width: Int, height: Int)?
    private var resizeTask: Task<Void, Never>?
    public static let resizeDebounce: Duration = .milliseconds(400)
    public static let desktopSizeRange = (width: 320...8192, height: 240...8192)
    private var quality = VNCQualityPolicy()
    public private(set) var closed = false
    public let initialDesktopSize: (width: Int, height: Int)?
    public var resizesDesktop: Bool { true }
    public var linkBitsPerSecond: Double? { quality.bitsPerSecond }

    public init(
      client: RFBClient, parameters: RFBServerParameters, metrics: ScreenSharingMetrics = ScreenSharingMetrics(),
      keys: VNCKeyTranslator = VNCKeyTranslator(),
      leaseChannel: (any RFBControlChannel)? = nil,
      sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
      self.client = client
      self.metrics = metrics
      self.sleep = sleep
      desktopSize = (parameters.width, parameters.height)
      initialDesktopSize = (parameters.width, parameters.height)
      metrics.label("vncQuality", VNCQualityPolicy().description)
      transportName = client.transportName
      translator = VNCInputTranslator(width: parameters.width, height: parameters.height, keys: keys)
      let (messages, continuation) = AsyncStream<RFBClientMessage>.makeStream()
      outbox = continuation
      sender = Task {
        for await message in messages {
          guard (try? await client.send(message)) != nil else { break }
        }
      }
      emulator = VNCHostEmulator(translator: translator, leaseChannel: leaseChannel) { continuation.yield($0) }
      metrics.label("decoder", "RFB")
      metrics.label("videoSize", "\(parameters.width) × \(parameters.height)")
      emulator.onRichClipboardSupported = { [weak self] in
        guard let self else { return }
        self.richClipboard = true
        self.onRichClipboardSupported?()
      }
      metrics.label("serverName", parameters.name)
      let publisher = publisher
      let frames = frames
      run = Task { [weak self] in
        do {
          try await client.run(
            onUpdate: { framebuffer, update in
              publisher.publish(
                framebuffer, changed: update.resized ? nil : update.rectangles, to: frames, metrics: metrics)
              metrics.increment("vncRectangles", by: update.rectangles.count)
              metrics.increment("vncBytesReceived", by: update.byteCount)
              var cursor: [ScreenSharingCursorUpdate] = []
              if let shape = update.cursor {
                cursor.append(.shape(shape))
                metrics.increment("vncCursorShapes")
              }
              if let pointer = update.pointer { cursor.append(.position(pointer)) }
              if update.jpegRectangles > 0 { metrics.increment("vncJPEGRectangles", by: update.jpegRectangles) }
              if update.linkBytes > 0 {
                let bytes = update.linkBytes, duration = update.linkDuration
                Task { @MainActor in self?.observeBandwidth(bytes: bytes, duration: duration) }
              }
              if let result = update.desktopSize {
                Task { @MainActor in self?.desktopSizeChanged(result) }
              }
              let announcedLayout = update.desktopSize != nil
              Task { @MainActor in self?.updateArrived(announcedLayout: announcedLayout) }
              if !cursor.isEmpty {
                Task { @MainActor in cursor.forEach { self?.onCursorChanged?($0) } }
              }
              if let latency = update.latency {
                metrics.observe("vncUpdateLatency", milliseconds: latency.milliseconds)
              }
              if update.resized {
                let width = framebuffer.width, height = framebuffer.height
                Task { @MainActor in self?.resized(width: width, height: height) }
              }
            },
            onEvent: { event in
              switch event {
              case .roundTrip(let duration): metrics.observe("vncRoundTrip", milliseconds: duration.milliseconds)
              case .continuousUpdates(let on): metrics.label("vncUpdateMode", on ? "continuous" : "requested")
              default: Task { @MainActor in self?.handle(event) }
              }
            })
        } catch {
          Task { @MainActor in self?.ended(with: error) }
          return error
        }
      }
    }

    public func outcome() async -> any Error { await run.value }

    public func statistics() async -> [String: String] { ["vnc.transport": transportName] }

    public func close() {
      guard !closed else { return }
      closed = true
      resizeTask?.cancel()
      emulator.close()
      outbox.finish()
      sender.cancel()
      client.close()
      frames.clear()
      onConnectionChanged = nil
      onCursorChanged = nil
      onResizeSupportChanged = nil
    }

    public func requestDesktopSize(width: Int, height: Int) {
      desiredSize = (
        min(max(width, Self.desktopSizeRange.width.lowerBound), Self.desktopSizeRange.width.upperBound),
        min(max(height, Self.desktopSizeRange.height.lowerBound), Self.desktopSizeRange.height.upperBound)
      )
      resizeTask?.cancel()
      let sleep = sleep
      resizeTask = Task { [weak self] in
        do { try await sleep(Self.resizeDebounce) } catch { return }
        self?.sendDesktopSizeIfNeeded()
      }
    }

    private func sendDesktopSizeIfNeeded() {
      resizeTask = nil
      guard !closed, resizeSupported, !resizeRefused, let desired = desiredSize,
        desired != desktopSize
      else { return }
      outbox.yield(
        .setDesktopSize(
          width: desired.width, height: desired.height,
          screens: [RFBScreen(id: screenID, x: 0, y: 0, width: desired.width, height: desired.height)]))
      metrics.increment("vncResizeRequests")
    }

    private func desktopSizeChanged(_ result: RFBDesktopSizeResult) {
      let firstLayout = !resizeSupported
      resizeSupported = true
      if let screen = result.screens.first { screenID = screen.id }
      if firstLayout, !resizeRefused { onResizeSupportChanged?(true) }
      if result.reason == .thisClient, result.status != .ok {
        if !resizeRefused { onResizeSupportChanged?(false) }
        resizeRefused = true
        metrics.label("vncResize", "refused (\(result.status))")
      }
      if firstLayout, resizeTask == nil { sendDesktopSizeIfNeeded() }
    }

    private func updateArrived(announcedLayout: Bool) {
      guard !firstUpdateSeen else { return }
      firstUpdateSeen = true
      if !announcedLayout, !resizeSupported { onResizeSupportChanged?(false) }
    }

    private func observeBandwidth(bytes: Int, duration: Duration) {
      guard !closed else { return }
      let change = quality.observe(bytes: bytes, duration: duration)
      metrics.label("vncQuality", quality.detail)
      guard let level = change else { return }
      let client = client
      Task { try? await client.setQualityLevel(level) }
    }

    public func setClipboardSharing(_ enabled: Bool) { emulator.sharing = enabled }
    private var richClipboard = false
    public var onRichClipboardSupported: (() -> Void)? {
      didSet { if richClipboard { onRichClipboardSupported?() } }
    }

    private func resized(width: Int, height: Int) {
      desktopSize = (width, height)
      translator.width = width
      translator.height = height
      metrics.label("videoSize", "\(width) × \(height)")
    }

    private func handle(_ event: RFBServerEvent) {
      switch event {
      case .bell: metrics.increment("vncBells")
      case .serverCutText(let text):
        emulator.serverCutText(text)
        metrics.increment("vncServerCutTexts")
      case .extendedClipboard(let message):
        emulator.extendedClipboard(message)
        metrics.increment("vncExtendedClipboardMessages")
      case .continuousUpdates, .roundTrip: break
      }
    }

    private func ended(with error: any Error) {
      guard !closed else { return }
      switch error as? RFBError {
      case .connectionClosed, .transport:
        onConnectionChanged?("disconnected")
      default:
        failure = error.localizedDescription
        metrics.label("vncFailure", error.localizedDescription)
        onConnectionChanged?("failed")
      }
    }
  }

  extension Duration {
    fileprivate var milliseconds: Double {
      let (seconds, attoseconds) = components
      return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
  }

  public enum VNCConnection {
    public static func open(
      host: String, port: UInt16, password: String?, username: String? = nil
    ) async throws -> (
      client: RFBClient, outcome: RFBHandshake.Outcome
    ) {
      try await open(
        transport: try await RFBNetworkTransport.connect(host: host, port: port), password: password,
        username: username)
    }

    public static func securityTypes(host: String, port: UInt16) async throws -> [UInt8] {
      let transport = try await RFBNetworkTransport.connect(host: host, port: port)
      defer { transport.close() }
      let stream = RFBInputStream(transport: transport)
      guard let version = RFBProtocolVersion.parse(try await stream.bytes(12)), version >= .v3_3 else {
        throw RFBError.protocolMismatch("no RFB greeting")
      }
      let chosen = version.negotiated
      try await transport.write(chosen.encoded)
      if chosen == .v3_3 { return [UInt8(clamping: try await stream.u32())] }
      return try await stream.bytes(Int(try await stream.u8()))
    }

    public static func open(
      transport: any RFBTransport, password: String?, username: String? = nil
    ) async throws -> (
      client: RFBClient, outcome: RFBHandshake.Outcome
    ) {
      let client = try RFBClient(transport: transport)
      do {
        return (client, try await client.connect(password: password, username: username))
      } catch {
        client.close()
        throw error
      }
    }
  }
#endif
