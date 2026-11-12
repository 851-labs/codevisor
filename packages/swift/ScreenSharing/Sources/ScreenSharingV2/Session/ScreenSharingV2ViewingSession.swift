import Foundation
import ScreenSharing
import Synchronization

@MainActor
public final class ScreenSharingV2ViewingSession: ScreenSharingSimulatorSession {
  public let metrics: ScreenSharingMetrics
  public let frames: ScreenSharingFrameMailbox
  public var onConnectionChanged: ((String) -> Void)?
  public var capabilities: ScreenSharingCapabilities { [.control, .clipboard, .statistics, .systemKeys] }
  public var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { channels.control }
  public var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { channels.clipboard }
  public var simulator: any ScreenSharingMessageChannel<ScreenSharingSimulatorMessage> { channels.simulator }
  public var failure: String? { nil }
  public private(set) var videoShowsPointer = true
  public var resizesDesktop: Bool { true }
  public var resizeMirrorsHostDisplay: Bool { true }
  public var supportsAudio: Bool { true }
  public var presentsTiles = false

  private let connection: any ScreenSharingV2Connection
  private let channels: ScreenSharingV2Channels
  private let audio: ScreenSharingV2ViewerAudio
  private var viewer: ScreenSharingV2Viewer?
  private var watcher: Task<Void, Never>?
  private var closed = false

  public init(connection: any ScreenSharingV2Connection, metrics: ScreenSharingMetrics = ScreenSharingMetrics()) {
    self.connection = connection
    self.metrics = metrics
    let feedBox = ScreenSharingV2FeedSlot()
    channels = ScreenSharingV2Channels { kind, payload in
      feedBox.sendDatagram(kind, payload)
    }
    frames = ScreenSharingFrameMailbox()
    audio = ScreenSharingV2ViewerAudio(channel: channels.audio, metrics: metrics)
    self.feedBox = feedBox
    wireChannels()
  }

  private let feedBox: ScreenSharingV2FeedSlot

  public func start(token: String) async throws {
    try await channels.open(on: connection, token: token)
    guard !closed else { throw CancellationError() }

    let audio = audio
    let channels = channels
    let feed = ScreenSharingV2MediaFeed(transport: await connection.openMedia()) { kind, payload in
      if kind == .audio, let packet = try? ScreenSharingAudioMessage.decode(payload), case .packet(let packet) = packet
      {
        audio.sink.receive(packet)
      } else {
        Task { @MainActor in channels.receiveDatagram(kind, payload) }
      }
    }
    guard !closed else {
      feed.close()
      throw CancellationError()
    }

    feedBox.set(feed)
    let viewer = ScreenSharingV2Viewer(
      transport: feed.attach(), metrics: metrics, frames: frames, presentsTiles: presentsTiles)
    self.viewer = viewer
    viewer.start()
    metrics.label("engine", "v2")
    route()
    onConnectionChanged?("connected")
    watcher = Task { [weak self, connection] in
      let reason = await connection.closed()
      guard let self, !self.closed else { return }

      self.metrics.label("connectionClosed", reason)
      self.onConnectionChanged?("failed")
    }
  }

  public func statistics() async -> [String: String] {
    guard !closed else { return [:] }

    var statistics = connection.mediaStatistics()
    statistics["v2.engine"] = "v2"
    if let route = connection.route {
      metrics.label("route", route.isRelay ? "relay" : "direct")
      statistics["v2.route"] = route.isRelay ? "relay" : "direct"
      statistics["v2.roundTripMs"] = String(route.roundTripMs)
    }
    return statistics
  }

  public func close() {
    guard !closed else { return }

    closed = true
    watcher?.cancel()
    audio.stop()
    channels.close()
    viewer?.stop()
    feedBox.close()
    connection.close("viewer closed")
    frames.clear()
  }

  private func route() {
    guard let route = connection.route else { return }

    metrics.label("route", route.isRelay ? "relay" : "direct")
  }

  public var onCursorChanged: ((ScreenSharingCursorUpdate) -> Void)? {
    didSet {
      subscribeToCursor()
      if let lastCursorShape { onCursorChanged?(lastCursorShape) }
      if let lastCursorPosition { onCursorChanged?(lastCursorPosition) }
    }
  }

  private var lastCursorShape: ScreenSharingCursorUpdate?
  private var lastCursorPosition: ScreenSharingCursorUpdate?
  private var subscribedToCursor = false

  private func subscribeToCursor() {
    guard onCursorChanged != nil, !subscribedToCursor, channels.cursor.isAvailable else { return }

    subscribedToCursor = channels.cursor.send(.subscribe)
  }

  private func receiveCursor(_ message: ScreenSharingCursorMessage) {
    switch message {
    case .subscribe: return
    case .shape(let image):
      guard let shape = image.shape() else {
        metrics.increment("cursorShapesRejected")
        return
      }
      if videoShowsPointer { metrics.label("pointer", "streamed") }
      videoShowsPointer = false
      let update = ScreenSharingCursorUpdate.sizedShape(shape, width: image.width, height: image.height)
      lastCursorShape = update
      onCursorChanged?(update)
    case .position(let pointer):
      let update = ScreenSharingCursorUpdate.normalizedPosition(pointer)
      lastCursorPosition = update
      onCursorChanged?(update)
    }
  }

  public var onResizeSupportChanged: ((Bool) -> Void)? {
    didSet { if let displaySupport { onResizeSupportChanged?(displaySupport) } }
  }

  private var displaySupport: Bool?
  private var requestedDesktop: ScreenSharingDisplayMessage?

  public func requestDesktopSize(width: Int, height: Int) { sendDisplay(.resize(width: width, height: height)) }

  public func resetDesktopSize() { sendDisplay(.restore) }

  private func sendDisplay(_ message: ScreenSharingDisplayMessage) {
    guard message != requestedDesktop else { return }

    requestedDesktop = message
    guard displaySupport == true else { return }

    channels.display.send(message)
  }

  private func receiveDisplay(_ message: ScreenSharingDisplayMessage) {
    switch message {
    case .ready:
      displaySupport = true
      onResizeSupportChanged?(true)
      if let requestedDesktop { channels.display.send(requestedDesktop) }
    case .unavailable(let reason):
      displaySupport = false
      metrics.label("desktopResize", reason)
      onResizeSupportChanged?(false)
    case .resized(let width, let height):
      metrics.label("desktopResize", "\(width)×\(height) pt")
    case .resize, .restore:
      return
    }
  }

  private var clipboardSharing = false
  private var richClipboard = false

  public var onRichClipboardSupported: (() -> Void)? {
    didSet { if richClipboard { onRichClipboardSupported?() } }
  }

  public func setClipboardSharing(_ enabled: Bool) {
    guard enabled != clipboardSharing else { return }

    clipboardSharing = enabled
    channels.clipboardSharing.send(.viewer(sharing: enabled, richContent: true))
  }

  public func setAudioEnabled(_ enabled: Bool) { audio.setEnabled(enabled) }

  public func setAudioVolume(_ volume: Float) { audio.setVolume(volume) }

  private func wireChannels() {
    channels.cursor.onMessage = { [weak self] in self?.receiveCursor($0) }
    channels.cursor.onAvailabilityChanged = { [weak self] available in
      if available { self?.subscribeToCursor() }
    }
    channels.display.onMessage = { [weak self] in self?.receiveDisplay($0) }
    channels.clipboardSharing.onAvailabilityChanged = { [weak self] available in
      guard available, let self else { return }

      self.channels.clipboardSharing.send(.viewer(sharing: self.clipboardSharing, richContent: true))
    }
    channels.clipboardSharing.onMessage = { [weak self] message in
      guard case .host(richContent: true) = message, let self, !self.richClipboard else { return }

      self.richClipboard = true
      self.onRichClipboardSupported?()
    }
    channels.videoFormat.onAvailabilityChanged = { [weak self] available in
      guard available else { return }

      self?.channels.videoFormat.send(.viewer(highDynamicRange: false))
    }
  }
}
