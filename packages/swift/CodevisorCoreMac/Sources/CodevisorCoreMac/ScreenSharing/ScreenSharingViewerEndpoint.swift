import AppKit
import ScreenSharing
import OSLog
import SystemConfiguration

@MainActor
public final class ScreenSharingViewerEndpoint: Equatable, Identifiable {
  public typealias ID = UUID
  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")
  public let id = ID()
  public let displayId: String?
  public let capabilities: ScreenSharingCapabilities
  public var supportsControl: Bool { capabilities.contains(.control) }
  public var supportsClipboard: Bool { capabilities.contains(.clipboard) }
  public var supportsSystemKeys: Bool { capabilities.contains(.systemKeys) }
  public var dropsInjectedInput: Bool {
    get { views.dropsInjectedInput }
    set { views.dropsInjectedInput = newValue }
  }
  public var localShortcuts: Set<ScreenSharingLocalShortcutGroup> {
    get { views.localShortcuts }
    set { views.localShortcuts = newValue }
  }
  public let clipboard: ScreenSharingViewerClipboard?
  public let diagnostics = ScreenSharingViewerDiagnostics()
  public var failure: String? { session.failure }
  var onViewFocusChanged: ((UUID, Bool) -> Void)?
  var onViewKeyboardReturned: ((UUID) -> Void)?
  var onViewResized: ((UUID) -> Void)?
  var onReady: (() -> Void)?
  let session: any ScreenSharingViewingSession
  private let views: ScreenSharingEndpointViews
  private let channel: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)?
  private let forwarder: ScreenSharingInputForwarder
  private var subscribers: [UUID: AsyncStream<ScreenSharingControlEvent>.Continuation] = [:]
  private var tickTask: Task<Void, Never>?
  private var clipboardTask: Task<Void, Never>?
  private var diagnosticsTask: Task<Void, Never>?
  private let firstFrame = UUID()
  private var receivedVideo = false
  private var reportedFailure = false
  private var closed = false

  nonisolated static func desktopSize(points: CGSize, scale: Int) -> (width: Int, height: Int) {
    (Int((points.width * CGFloat(scale)).rounded()), Int((points.height * CGFloat(scale)).rounded()))
  }

  public var supportsDynamicResolution: Bool { session.resizesDesktop }
  public var resizeMirrorsHostDisplay: Bool { session.resizeMirrorsHostDisplay }
  public let resolutionAvailability = ScreenSharingResolutionAvailability()
  public private(set) var audio: ScreenSharingAudioControl?
  private var desktopResizes: Bool? {
    didSet { updateResolutionAvailability() }
  }
  public private(set) var dynamicResolution = false

  public var highDynamicRange = false {
    didSet { if highDynamicRange != oldValue { reportHighDynamicRange() } }
  }
  public var supportsHighDynamicRange: Bool { session.supportsHighDynamicRange }
  public var screenShowsHighDynamicRange: Bool { views.screenShowsHighDynamicRange }
  public private(set) var hostDynamicRange: (range: ScreenSharingDynamicRange, reason: String?)?

  public var highDynamicRangeNote: String? {
    guard highDynamicRange, supportsHighDynamicRange else { return nil }
    if !screenShowsHighDynamicRange { return "This Mac's screen can't show HDR. Move the window to an HDR display." }
    if dynamicResolution { return "HDR is off while Dynamic Resolution is on." }
    guard let host = hostDynamicRange else { return nil }
    return host.range == .high ? nil : host.reason
  }

  private func reportHighDynamicRange() {
    session.setDisplayHighDynamicRange(highDynamicRange && screenShowsHighDynamicRange)
  }
  var setDesktopScale: (@MainActor (Int) async -> Void)?
  public var defaultDesktopSize: (width: Int, height: Int)?
  public var desktopCanScale = false {
    didSet { updateResolutionAvailability() }
  }
  private var paneSize: (points: CGSize, backingScale: CGFloat)? { views.size }
  private var resolution = ScreenSharingDynamicResolution()
  private var changedDesktop = false
  private var appliedScale: Int?

  public func setDynamicResolution(_ enabled: Bool) {
    guard enabled != dynamicResolution else { return }
    dynamicResolution = enabled
    applyResolution()
  }

  private func updateResolutionAvailability() {
    resolutionAvailability.available = desktopCanScale ? true : desktopResizes
  }

  private func applyResolution() {
    guard !closed, session.resizesDesktop else { return }
    if dynamicResolution, let pane = paneSize {
      let scale =
        desktopCanScale
        ? resolution.scale(backingScale: pane.backingScale, bitsPerSecond: session.linkBitsPerSecond) : 1
      let desktop = Self.desktopSize(points: pane.points, scale: scale)
      session.requestDesktopSize(width: desktop.width, height: desktop.height)
      changedDesktop = true
      applyDesktopScale(scale)
    } else if !dynamicResolution, changedDesktop {
      changedDesktop = false
      if let size = defaultDesktopSize ?? session.initialDesktopSize {
        session.requestDesktopSize(width: size.width, height: size.height)
      }
      session.resetDesktopSize()
      if appliedScale == 2 { applyDesktopScale(1) }
    }
    let slow = (session.linkBitsPerSecond ?? .infinity) < ScreenSharingDynamicResolution.oneXBelowBitsPerSecond
    session.metrics.label(
      "resolution",
      ScreenSharingDynamicResolution.label(
        enabled: dynamicResolution, scale: resolution.scale, backingScale: paneSize?.backingScale ?? 1, slowLink: slow))
  }

  private func applyDesktopScale(_ scale: Int) {
    guard scale != appliedScale, let setDesktopScale else { return }
    appliedScale = scale
    Task { @MainActor in await setDesktopScale(scale) }
  }

  convenience init(
    session: any ScreenSharingViewingSession, surface: any ScreenSharingViewerSurface, sound: Bool = true,
    displayId: String? = nil
  ) {
    self.init(session: session, sound: sound, displayId: displayId, makeSurface: nil)
    views.adopt(surface, as: id)
  }

  init(
    session: any ScreenSharingViewingSession, sound: Bool = true, displayId: String? = nil,
    makeSurface: ScreenSharingEndpointViews.Make?
  ) {
    self.displayId = displayId
    self.session = session
    views = ScreenSharingEndpointViews(frames: session.frames, timeline: session.metrics.timeline, make: makeSurface)
    capabilities = session.capabilities
    session.frames.retainsLatest = true
    channel = session.control
    let (channel, views) = (session.control, views)
    forwarder = ScreenSharingInputForwarder(
      send: { [weak channel] in channel?.send($0) ?? false }, heartbeat: Self.backgroundHeartbeat(on: channel))
    clipboard = session.clipboard.map { channel in
      ScreenSharingViewerClipboard(
        channel: channel, setHostSharing: { [weak session] in session?.setClipboardSharing($0) },
        hasKeyboardFocus: { [weak views] in
          guard let views, let window = views.controlled?.view.window else { return false }
          return window.isKeyWindow && views.hasKeyboardFocus(in: views.active)
        })
    }
    session.onRichClipboardSupported = { [weak clipboard] in clipboard?.hostAcceptsRichContent() }
    channel?.onMessage = { [weak self] in self?.emit(.message($0)) }
    channel?.onAvailabilityChanged = { [weak self] in self?.emit(.availability($0)) }
    forwarder.onLost = { [weak self] reason in
      self?.views.controlled?.endInput()
      self?.emit(.inputLost(reason))
    }
    followViews()
    followSession(sound: sound)
    tickTask = makeTickTask()
    if clipboard != nil { clipboardTask = makeClipboardTask() }
    diagnosticsTask = makeDiagnosticsTask()
    ScreenSharingEndpointRegistry.shared.register(self)
  }

  private func followViews() {
    views.events.keyboardReturned = { [weak self] in self?.onViewKeyboardReturned?($0) }
    views.events.focusChanged = { [weak self] id, focused in
      if focused, id == self?.views.active { self?.clipboard?.poll() }
      self?.onViewFocusChanged?(id, focused)
    }
    views.events.input = { [weak forwarder] in forwarder?.forward($0) }
    views.events.inputReleased = { [weak self] reason in
      self?.forwarder.end()
      self?.emit(.inputLost(reason))
    }
    views.events.sizeChanged = { [weak self] in self?.applyResolution() }
    views.events.viewResized = { [weak self] in self?.onViewResized?($0) }
    views.events.screenChanged = { [weak self] in self?.reportHighDynamicRange() }
  }

  private func followSession(sound: Bool) {
    views.setVideoShowsPointer(session.videoShowsPointer)
    session.onCursorChanged = { [weak views, weak session] update in
      if let session { views?.setVideoShowsPointer(session.videoShowsPointer) }
      views?.showRemoteCursor(update)
    }
    session.onResizeSupportChanged = { [weak self] in self?.desktopResizes = $0 }
    if session.supportsAudio { audio = ScreenSharingAudioControl(session: session, enabled: sound) }
    session.onVideoFormatChanged = { [weak self] in self?.hostDynamicRange = ($0, $1) }
    session.frames.tap(firstFrame).onFrameAvailable { [weak self] in Task { @MainActor in self?.noteFirstFrame() } }
  }

  private func makeTickTask() -> Task<Void, Never> {
    Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self else { return }
        self.clipboard?.tick()
        if self.dynamicResolution { self.applyResolution() }
        if self.session.failure != nil, !self.reportedFailure {
          self.reportedFailure = true
          self.emit(.sessionFailed("Video decoding failed. Reconnect before controlling."))
        }
      }
    }
  }

  private func makeClipboardTask() -> Task<Void, Never> {
    Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        self?.clipboard?.poll()
      }
    }
  }

  private func makeDiagnosticsTask() -> Task<Void, Never> {
    let statsLogId = id
    return Task { [weak self] in
      let statsLog = Self.openStatsLog(for: statsLogId)
      var exportedFrames: UInt64 = 0
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        if let self, self.receivedVideo {
          let statistics = await self.session.statistics()
          guard !Task.isCancelled else { return }
          exportedFrames = self.recordDiagnostics(statistics, to: statsLog, after: exportedFrames)
        }
      }
    }
  }

  private func recordDiagnostics(
    _ statistics: [String: String], to statsLog: FileHandle?, after exported: UInt64
  )
    -> UInt64
  {
    session.metrics.timeline.observeTransport(statistics)
    let metrics = views.measured.map(session.metrics.snapshot().merging) ?? session.metrics.snapshot()
    let now = ProcessInfo.processInfo.systemUptime
    diagnostics.update(metrics: metrics, timeline: session.metrics.timeline, statistics: statistics, now: now)
    guard let statsLog else { return exported }

    let frames = session.metrics.timeline.records(after: exported)
    let record = StatsRecord(
      time: now, statistics: statistics, metrics: metrics, timeline: session.metrics.timeline.summary(),
      frames: frames)
    if let line = try? JSONEncoder().encode(record) { statsLog.write(line + Data("\n".utf8)) }
    return frames.last?.sequence ?? exported
  }

  static func systemShortcutsNotice(
    appName: String = NSRunningApplication.current.localizedName ?? "Codevisor",
    macName: String = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "this Mac"
  ) -> String {
    "⌘Tab, ⌘Space and other system shortcuts stay on \(macName). To send them too, allow \(appName) in "
      + "System Settings → Privacy & Security → Accessibility on \(macName)."
  }

  private struct StatsRecord: Encodable {
    let time: TimeInterval
    let statistics: [String: String]
    let metrics: ScreenSharingMetrics.Snapshot
    let timeline: ScreenSharingFrameTimelineSummary?
    let frames: [ScreenSharingFrameRecord]
  }

  private static func openStatsLog(for id: ID) -> FileHandle? {
    guard let directory = ProcessInfo.processInfo.environment["CODEVISOR_SCREEN_SHARING_STATS_LOG"] else {
      return nil
    }
    let file = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("\(id.uuidString).jsonl")
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: file.path, contents: nil) else { return nil }
    return try? FileHandle(forWritingTo: file)
  }

  func controlEvents() -> AsyncStream<ScreenSharingControlEvent> {
    let (stream, continuation) = AsyncStream<ScreenSharingControlEvent>.makeStream()
    guard !closed else {
      continuation.finish()
      return stream
    }
    let token = UUID()
    subscribers[token] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.subscribers[token] = nil }
    }
    continuation.yield(.availability(channel?.isAvailable ?? false))
    return stream
  }

  @discardableResult
  func sendControl(_ message: ScreenSharingControlMessage) -> Bool {
    if case .heartbeat = message, forwarder.keepsLeaseAlive { return channel?.isAvailable ?? false }

    return channel?.send(message) ?? false
  }

  private static func backgroundHeartbeat(
    on channel: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)?
  ) -> ScreenSharingInputForwarder.Heartbeat? {
    guard let sender = channel as? any ScreenSharingBackgroundSending<ScreenSharingControlMessage> else { return nil }

    return { sender.sendFromAnyThread(.heartbeat(lease: $0)) }
  }

  func beginInput(lease: UUID) -> String? {
    guard let surface = views.controlled else { return "Focus this window and request control again." }
    guard surface.beginInput() else { return surface.inputFailureMessage }
    forwarder.begin(lease: lease)
    clipboard?.setControlling(true)
    if supportsSystemKeys, !surface.capturesSystemShortcuts { emit(.inputNotice(Self.systemShortcutsNotice())) }
    if let key = pendingSystemKey {
      pendingSystemKey = nil
      press(key)
    }
    return nil
  }

  func relinquish() {
    if let lease = forwarder.lease { _ = channel?.send(.release(lease: lease)) }
    endInput()
  }

  func endInput() {
    pendingSystemKey = nil
    clipboard?.setControlling(false)
    forwarder.end()
    views.controlled?.endInput()
  }

  private var pendingSystemKey: ScreenSharingSystemKey?

  public func tap(_ key: ScreenSharingSystemKey) {
    guard forwarder.isActive else {
      pendingSystemKey = key
      return
    }
    press(key)
  }

  private func press(_ key: ScreenSharingSystemKey) {
    for down in [true, false] {
      forwarder.forward(.key(code: key.rawValue, down: down, repeatKey: false, modifiers: 0))
    }
  }

  public func view(for pane: UUID) -> NSView? {
    closed ? nil : views.view(for: pane)
  }

  public func letterbox(_ color: NSColor, in pane: UUID) { views.letterbox(color, in: pane) }

  public func hasKeyboardFocus(in pane: UUID) -> Bool { views.hasKeyboardFocus(in: pane) }

  func removeView(for pane: UUID) {
    if views.active == pane { moveInput(to: nil) }
    views.remove(pane)
  }

  func size(of pane: UUID) -> CGSize? { views.size(of: pane) }

  func sizeDesktop(with pane: UUID?) { views.drive(with: pane) }

  func moveInput(to pane: UUID?) {
    guard pane != views.active else { return }

    views.controlled?.endInput()
    views.activate(pane)
    guard forwarder.isActive, let surface = views.controlled else { return }
    guard surface.beginInput() else {
      forwarder.end()
      return emit(.inputLost(surface.inputFailureMessage))
    }
  }

  private func noteFirstFrame() {
    session.frames.untap(firstFrame)
    guard !receivedVideo, !closed else { return }
    receivedVideo = true
    onReady?()
  }

  private func emit(_ event: ScreenSharingControlEvent) {
    guard !closed else { return }
    for continuation in subscribers.values { continuation.yield(event) }
  }

  func close() {
    guard !closed else { return }
    closed = true
    ScreenSharingEndpointRegistry.shared.unregister(id)
    relinquish()
    clipboard?.close()
    tickTask?.cancel(); tickTask = nil
    clipboardTask?.cancel(); clipboardTask = nil
    diagnosticsTask?.cancel(); diagnosticsTask = nil
    for continuation in subscribers.values { continuation.finish() }
    subscribers = [:]
    let metrics = session.metrics.snapshot()
    Self.logger.info(
      "Viewer ended: \(String(describing: metrics.counters), privacy: .public), \(String(describing: metrics.labels), privacy: .public)"
    )
    onReady = nil
    session.frames.untap(firstFrame)
    session.frames.retainsLatest = false
    views.stop()
    session.close()
  }

  nonisolated public static func == (lhs: ScreenSharingViewerEndpoint, rhs: ScreenSharingViewerEndpoint) -> Bool {
    lhs === rhs
  }
}

@MainActor
@Observable
public final class ScreenSharingResolutionAvailability {
  public internal(set) var available: Bool?
  init() {}
}

@MainActor
@Observable
public final class ScreenSharingAudioControl {
  public var enabled: Bool {
    didSet { if enabled != oldValue { session?.setAudioEnabled(plays) } }
  }
  var audible = true {
    didSet { if audible != oldValue { session?.setAudioEnabled(plays) } }
  }
  public var volume: Double {
    didSet { if volume != oldValue { session?.setAudioVolume(Float(volume)) } }
  }
  @ObservationIgnored private weak var session: (any ScreenSharingViewingSession)?
  private var plays: Bool { enabled && audible }

  init(session: any ScreenSharingViewingSession, enabled: Bool = true, volume: Double = 1) {
    self.session = session
    self.enabled = enabled
    self.volume = volume
    session.setAudioEnabled(enabled)
    session.setAudioVolume(Float(volume))
  }

  public func apply(_ sound: ScreenSharingMachineSettings.Sound) {
    enabled = sound.enabled
    volume = sound.volume
  }
}
