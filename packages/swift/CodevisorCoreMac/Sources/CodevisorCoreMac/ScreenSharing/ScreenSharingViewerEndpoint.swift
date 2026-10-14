import AppKit
import ScreenSharing
import OSLog
import SystemConfiguration

@MainActor
public final class ScreenSharingViewerEndpoint: Equatable, Identifiable {
  public typealias ID = UUID
  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")
  public let id = ID()
  public let capabilities: ScreenSharingCapabilities
  public var supportsControl: Bool { capabilities.contains(.control) }
  public var supportsClipboard: Bool { capabilities.contains(.clipboard) }
  public var supportsSystemKeys: Bool { capabilities.contains(.systemKeys) }
  public var view: NSView { surface.view }
  public var dropsInjectedInput: Bool {
    get { surface.dropsInjectedInput }
    set { surface.dropsInjectedInput = newValue }
  }
  public var videoHasKeyboardFocus: Bool { view.window?.firstResponder === view }
  public let clipboard: ScreenSharingViewerClipboard?
  public let diagnostics = ScreenSharingViewerDiagnostics()
  public var failure: String? { session.failure }
  public var onFocusChanged: ((Bool) -> Void)?
  public var onKeyboardReturned: (() -> Void)?
  var onReady: (() -> Void)?
  let session: any ScreenSharingViewingSession
  private let surface: any ScreenSharingViewerSurface
  private let channel: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)?
  private let forwarder: ScreenSharingInputForwarder
  private var subscribers: [UUID: AsyncStream<ScreenSharingControlEvent>.Continuation] = [:]
  private var tickTask: Task<Void, Never>?
  private var clipboardTask: Task<Void, Never>?
  private var diagnosticsTask: Task<Void, Never>?
  private var presented = false
  private var reportedFailure = false
  private var closed = false

  nonisolated static func desktopSize(points: CGSize, scale: Int) -> (width: Int, height: Int) {
    (Int((points.width * CGFloat(scale)).rounded()), Int((points.height * CGFloat(scale)).rounded()))
  }

  public var supportsDynamicResolution: Bool { session.resizesDesktop }
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
  public private(set) var screenShowsHighDynamicRange = false
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
  private var paneSize: (points: CGSize, backingScale: CGFloat)?
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

  init(session: any ScreenSharingViewingSession, surface: any ScreenSharingViewerSurface) {
    self.session = session
    self.surface = surface
    capabilities = session.capabilities
    channel = session.control
    let channel = session.control
    forwarder = ScreenSharingInputForwarder(send: { [weak channel] in channel?.send($0) ?? false })
    clipboard = session.clipboard.map { channel in
      ScreenSharingViewerClipboard(
        channel: channel, setHostSharing: { [weak session] in session?.setClipboardSharing($0) },
        hasKeyboardFocus: { [weak surface] in
          guard let view = surface?.view, let window = view.window else { return false }
          return window.isKeyWindow && window.firstResponder === view
        })
    }
    channel?.onMessage = { [weak self] in self?.emit(.message($0)) }
    channel?.onAvailabilityChanged = { [weak self] in self?.emit(.availability($0)) }
    forwarder.onLost = { [weak self] reason in
      self?.surface.endInput()
      self?.emit(.inputLost(reason))
    }
    surface.onKeyboardReturned = { [weak self] in self?.onKeyboardReturned?() }
    surface.onFocusChanged = { [weak self] focused in
      if focused { self?.clipboard?.poll() }
      self?.onFocusChanged?(focused)
    }
    surface.onInput = { [weak forwarder] in forwarder?.forward($0) }
    surface.onInputReleased = { [weak self] in
      guard let self else { return }
      self.forwarder.end()
      self.emit(.inputLost(self.surface.inputFailureMessage))
    }
    surface.setVideoShowsPointer(session.videoShowsPointer)
    session.onCursorChanged = { [weak surface, weak session] update in
      if let session { surface?.setVideoShowsPointer(session.videoShowsPointer) }
      surface?.showRemoteCursor(update)
    }
    session.onResizeSupportChanged = { [weak self] in self?.desktopResizes = $0 }
    if session.supportsAudio { audio = ScreenSharingAudioControl(session: session) }
    surface.onSizeChanged = { [weak self] size, scale in
      self?.paneSize = (size, scale)
      self?.applyResolution()
    }
    surface.onScreenHighDynamicRangeChanged = { [weak self] in
      self?.screenShowsHighDynamicRange = $0
      self?.reportHighDynamicRange()
    }
    session.onVideoFormatChanged = { [weak self] in self?.hostDynamicRange = ($0, $1) }
    surface.onPresented = { [weak self] in
      guard let self, !self.presented else { return }
      self.presented = true
      self.onReady?()
    }
    tickTask = Task { [weak self] in
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
    if clipboard != nil {
      clipboardTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          self?.clipboard?.poll()
        }
      }
    }
    let statsLogId = id
    diagnosticsTask = Task { [weak self] in
      let statsLog = Self.openStatsLog(for: statsLogId)
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        if let self, self.presented {
          let statistics = await self.session.statistics()
          guard !Task.isCancelled else { return }
          let metrics = self.session.metrics.snapshot()
          let now = ProcessInfo.processInfo.systemUptime
          self.diagnostics.update(metrics: metrics, statistics: statistics, now: now)
          if let statsLog,
            let line = try? JSONEncoder().encode(StatsRecord(time: now, statistics: statistics, metrics: metrics))
          {
            statsLog.write(line + Data("\n".utf8))
          }
        }
      }
    }
    ScreenSharingEndpointRegistry.shared.register(self)
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
  func sendControl(_ message: ScreenSharingControlMessage) -> Bool { channel?.send(message) ?? false }

  func beginInput(lease: UUID) -> String? {
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

  func endInput() {
    pendingSystemKey = nil
    clipboard?.setControlling(false)
    forwarder.end()
    surface.endInput()
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

  public func letterbox(_ color: NSColor) { surface.setLetterboxColor(color) }

  private func emit(_ event: ScreenSharingControlEvent) {
    guard !closed else { return }
    for continuation in subscribers.values { continuation.yield(event) }
  }

  func close() {
    guard !closed else { return }
    closed = true
    ScreenSharingEndpointRegistry.shared.unregister(id)
    if let lease = forwarder.lease { _ = channel?.send(.release(lease: lease)) }
    endInput()
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
    surface.stop()
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
    didSet { if enabled != oldValue { session?.setAudioEnabled(enabled) } }
  }
  public var volume: Double {
    didSet { if volume != oldValue { session?.setAudioVolume(Float(volume)) } }
  }
  @ObservationIgnored private weak var session: (any ScreenSharingViewingSession)?

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
