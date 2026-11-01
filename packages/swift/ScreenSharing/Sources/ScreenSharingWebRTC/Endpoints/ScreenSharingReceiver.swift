import Foundation
import os
@preconcurrency import WebRTC
import ScreenSharing

@MainActor
public final class ScreenSharingReceiver: ScreenSharingPeer, ScreenSharingViewingSession {
  public let mailbox: ScreenSharingFrameMailbox
  private let renderer: ScreenSharingPeerRenderer
  private let recovery: ScreenSharingReceiverRecovery

  public init(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    options: ScreenSharingPeerOptions = .init(), connectivity: ScreenSharingICEConfiguration? = nil
  ) async throws {
    let (staged, _) = try await ScreenSharingPeerStaging.make(
      configuration: configuration, metrics: metrics, options: options, connectivity: connectivity
    ) { _, connection, _, _ in
      let transceiver = RTCRtpTransceiverInit()
      transceiver.direction = .recvOnly
      guard connection.addTransceiver(of: .video, init: transceiver) != nil else {
        throw ScreenSharingError.unavailable("Cannot create screen video receiver.")
      }
    }
    let mailbox = ScreenSharingFrameMailbox()
    self.mailbox = mailbox
    let renderer = ScreenSharingPeerRenderer(mailbox: mailbox, metrics: metrics)
    self.renderer = renderer
    let inboundVideo = ScreenSharingInboundVideo(transport: staged.transport)
    recovery = ScreenSharingReceiverRecovery(
      metrics: metrics, codecFactory: staged.codecFactory, videoRefresh: staged.videoRefresh,
      receivedMediaBytes: { await inboundVideo.bytesReceived() })
    super.init(staged: staged)
    delegate.onVideoTrack = { [transport] track in transport.attach(track, renderer: renderer) }
    codecFactory.refreshSignal.request()
    cursorChannel.onMessage = { [weak self] in self?.receiveCursor($0) }
    cursorChannel.onAvailabilityChanged = { [weak self] available in
      if available { self?.subscribeToCursor() }
    }
    displayChannel.onMessage = { [weak self] in self?.receiveDisplay($0) }
    videoFormatChannel.onMessage = { [weak self] in self?.receiveVideoFormat($0) }
    videoFormatChannel.onAvailabilityChanged = { [weak self] available in
      guard available, let self, let viewerHighDynamicRange = self.viewerHighDynamicRange else { return }
      self.videoFormatChannel.send(.viewer(highDynamicRange: viewerHighDynamicRange))
    }
    clipboardSharingChannel.onAvailabilityChanged = { [weak self] available in
      guard available, let self else { return }
      self.clipboardSharingChannel.send(.viewer(sharing: self.clipboardSharing, richContent: true))
    }
    clipboardSharingChannel.onMessage = { [weak self] message in
      guard case .host(richContent: true) = message, let self, !self.richClipboard else { return }
      self.richClipboard = true
      self.onRichClipboardSupported?()
    }
    audioChannel.deliverOffMain { [audioSink] message in
      guard case .packet(let packet) = message else { return false }
      audioSink.receive(packet)
      return true
    }
    audioChannel.onAvailabilityChanged = { [weak self] available in
      if available { self?.subscribeToAudio() } else { self?.audioSubscribed = false }
    }
  }

  public var capabilities: ScreenSharingCapabilities { [.control, .clipboard, .statistics, .systemKeys] }
  public var frames: ScreenSharingFrameMailbox { mailbox }
  public var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { controlChannel }
  public var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { clipboardChannel }
  public var failure: String? { metrics.label("decoderError") }

  public private(set) var videoShowsPointer = true
  public var onCursorChanged: ((ScreenSharingCursorUpdate) -> Void)? {
    didSet {
      subscribeToCursor()
      if let shape = lastCursorShape { onCursorChanged?(shape) }
      if let position = lastCursorPosition { onCursorChanged?(position) }
    }
  }

  public var resizesDesktop: Bool { true }
  public var onResizeSupportChanged: ((Bool) -> Void)? {
    didSet { if let displaySupport { onResizeSupportChanged?(displaySupport) } }
  }
  private var displaySupport: Bool?
  private var requestedDesktop: ScreenSharingDisplayMessage?

  public func requestDesktopSize(width: Int, height: Int) {
    sendDisplay(.resize(width: width, height: height))
  }

  public func resetDesktopSize() { sendDisplay(.restore) }

  private func sendDisplay(_ message: ScreenSharingDisplayMessage) {
    guard message != requestedDesktop else { return }
    requestedDesktop = message
    guard displaySupport == true else { return }
    displayChannel.send(message)
  }

  private func receiveDisplay(_ message: ScreenSharingDisplayMessage) {
    switch message {
    case .ready:
      displaySupport = true
      onResizeSupportChanged?(true)
      if let requestedDesktop { displayChannel.send(requestedDesktop) }
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

  public var supportsHighDynamicRange: Bool { true }
  public var onVideoFormatChanged: ((ScreenSharingDynamicRange, String?) -> Void)?

  private var viewerHighDynamicRange: Bool?

  public func setDisplayHighDynamicRange(_ supported: Bool) {
    guard supported != viewerHighDynamicRange else { return }
    viewerHighDynamicRange = supported
    metrics.label("viewerHighDynamicRange", supported ? "yes" : "no")
    videoFormatChannel.send(.viewer(highDynamicRange: supported))
  }

  private func receiveVideoFormat(_ message: ScreenSharingVideoFormatMessage) {
    guard case .sending(let range, let reason) = message else { return }
    onVideoFormatChanged?(range, reason)
    metrics.label("hostDynamicRange", reason.map { "\(range.rawValue): \($0)" } ?? range.rawValue)
  }

  private var clipboardSharing = false
  private var richClipboard = false
  public var onRichClipboardSupported: (() -> Void)? {
    didSet { if richClipboard { onRichClipboardSupported?() } }
  }

  public func setClipboardSharing(_ enabled: Bool) {
    guard enabled != clipboardSharing else { return }
    clipboardSharing = enabled
    clipboardSharingChannel.send(.viewer(sharing: enabled, richContent: true))
  }

  public var supportsAudio: Bool { true }
  private var audioPlayer: ScreenSharingAudioPlayer? {
    didSet { audioSink.player = audioPlayer }
  }
  private let audioSink = ScreenSharingAudioSink()
  private var audioWanted = false
  private var audioSubscribed = false
  private var audioSync: Task<Void, Never>?

  public func setAudioEnabled(_ enabled: Bool) {
    audioWanted = enabled
    if enabled {
      if audioPlayer == nil {
        do {
          let player = try ScreenSharingAudioPlayer()
          player.setVolume(audioVolume)
          player.start { [weak self, metrics] error in
            metrics.label("audioError", error.localizedDescription)
            Task { @MainActor in self?.audioOutputFailed(player) }
          }
          audioPlayer = player
        } catch {
          metrics.label("audioError", error.localizedDescription)
          return
        }
      }
      subscribeToAudio()
      audioSync = audioSync ?? Task { [weak self] in await self?.followVideoDelay() }
    } else {
      stopAudio()
    }
  }

  private func stopAudio() {
    if audioSubscribed { audioChannel.send(.unsubscribe) }
    audioSubscribed = false
    audioSync?.cancel()
    audioSync = nil
    audioPlayer?.stop()
    audioPlayer = nil
  }

  private func audioOutputFailed(_ player: ScreenSharingAudioPlayer) {
    guard audioPlayer === player else { return }
    audioWanted = false
    stopAudio()
  }

  private var audioVolume: Float = 1 {
    didSet { audioPlayer?.setVolume(audioVolume) }
  }

  public func setAudioVolume(_ volume: Float) { audioVolume = min(1, max(0, volume)) }

  private func subscribeToAudio() {
    guard audioWanted, !audioSubscribed, audioChannel.isAvailable else { return }
    audioSubscribed = audioChannel.send(.subscribe)
  }

  static func audioTarget(videoDelay: Double, margin: Double) -> Double { max(0.06, videoDelay) + margin }

  static func audioMargin(_ margin: Double, newUnderruns: Int) -> Double {
    newUnderruns > 0 ? min(0.12, margin + 0.01 * Double(newUnderruns)) : max(0, margin - 0.002)
  }

  private func followVideoDelay() async {
    var previous: (delay: Double, emitted: Double)?
    var margin = 0.0
    var underruns = 0
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      let statistics = await self.statistics()
      guard let player = audioPlayer else { return }
      let delay = statistics.first { $0.key.hasPrefix("inbound-rtp.") && $0.key.hasSuffix(".jitterBufferDelay") }
        .flatMap { Double($0.value) }
      let emitted = statistics.first {
        $0.key.hasPrefix("inbound-rtp.") && $0.key.hasSuffix(".jitterBufferEmittedCount")
      }.flatMap { Double($0.value) }
      guard let delay, let emitted else { continue }
      let counted = player.statistics.underruns
      margin = Self.audioMargin(margin, newUnderruns: counted - underruns)
      underruns = counted
      if let previous, emitted > previous.emitted {
        let videoDelay = (delay - previous.delay) / (emitted - previous.emitted) + 0.02
        let target = Self.audioTarget(videoDelay: videoDelay, margin: margin)
        player.setTargetDelay(target)
        if audioSink.packetsReceived > 0 { metrics.label("audioTargetDelayMs", String(Int(target * 1000))) }
      }
      previous = (delay, emitted)
      let buffer = player.statistics
      metrics.label(
        "audio",
        "buffered \(buffer.buffered) frames, underruns \(buffer.underruns), lost \(buffer.lost), dropped \(buffer.dropped)"
      )
    }
  }

  private var lastCursorShape: ScreenSharingCursorUpdate?
  private var lastCursorPosition: ScreenSharingCursorUpdate?
  private var subscribedToCursor = false

  private func subscribeToCursor() {
    guard onCursorChanged != nil, !subscribedToCursor, cursorChannel.isAvailable else { return }
    subscribedToCursor = cursorChannel.send(.subscribe)
  }

  private func receiveCursor(_ message: ScreenSharingCursorMessage) {
    switch message {
    case .subscribe:
      return
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

  override func handleRefresh(_ message: ScreenSharingVideoRefreshMessage) {
    recovery.handle(message)
  }

  override func refreshChannelBecameAvailable() {
    recovery.wake()
  }

  override func willClose() {
    audioSync?.cancel()
    audioPlayer?.stop()
    audioPlayer = nil
    codecFactory.refreshSignal.close()
    ownedWork.close(with: recovery.close())
    codecFactory.sourceIdleMonitor.stop()
    renderer.stop()
  }

  override func didClose() {
    mailbox.clear()
  }
}

final class ScreenSharingAudioSink: Sendable {
  private let state = OSAllocatedUnfairLock<(player: ScreenSharingAudioPlayer?, packets: Int)>(
    initialState: (nil, 0))

  var player: ScreenSharingAudioPlayer? {
    get { state.withLock { $0.player } }
    set { state.withLock { $0.player = newValue } }
  }

  var packetsReceived: Int { state.withLock { $0.packets } }

  func receive(_ packet: ScreenSharingAudioPacket) {
    let player = state.withLock { state in
      state.packets += 1
      return state.player
    }
    player?.receive(packet)
  }
}
