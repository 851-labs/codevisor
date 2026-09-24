import AppKit
import ScreenSharing
import OSLog

/// One connected viewing endpoint, for any backend: the surface rendering the
/// session's frames, the control channel and input forwarding the lease
/// reducer drives through `ScreenSharingEndpointClient`, the explicit
/// clipboard transfer, and the diagnostics sampled from the session. Equal by
/// identity — the reducer keeps the live endpoint in state for the view and
/// addresses it by `id` for everything else.
///
/// Clipboard and diagnostics stay `@Observable` objects: they are data-plane
/// state (chunk transfers, 1 Hz samples) that the pane observes directly.
@MainActor
public final class ScreenSharingViewerEndpoint: Equatable, Identifiable {
  public typealias ID = UUID
  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")
  public let id = ID()
  public let capabilities: ScreenSharingCapabilities
  /// The lease-based control protocol is available on this session.
  public var supportsControl: Bool { capabilities.contains(.control) }
  /// The explicit text clipboard protocol is available on this session.
  public var supportsClipboard: Bool { capabilities.contains(.clipboard) }
  public var view: NSView { surface.view }
  public let clipboard: ScreenSharingViewerClipboard?
  public let diagnostics = ScreenSharingViewerDiagnostics()
  public var failure: String? { session.failure }
  /// Set by the pane: keyboard focus moved into or out of the video surface.
  public var onFocusChanged: ((Bool) -> Void)? {
    get { surface.onFocusChanged }
    set { surface.onFocusChanged = newValue }
  }
  /// The first presented frame; fired at most once. The backend turns it into `.ready`.
  var onReady: (() -> Void)?
  let session: any ScreenSharingViewingSession
  private let surface: any ScreenSharingViewerSurface
  private let channel: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)?
  private let forwarder: ScreenSharingInputForwarder
  private var subscribers: [UUID: AsyncStream<ScreenSharingControlEvent>.Continuation] = [:]
  private var tickTask: Task<Void, Never>?
  private var diagnosticsTask: Task<Void, Never>?
  private var presented = false
  private var reportedFailure = false
  private var closed = false

  /// The remote desktop size for a pane of `points` at `scale` remote pixels per point.
  nonisolated static func desktopSize(points: CGSize, scale: Int) -> (width: Int, height: Int) {
    (Int((points.width * CGFloat(scale)).rounded()), Int((points.height * CGFloat(scale)).rounded()))
  }

  // MARK: Dynamic Resolution (851-2340)

  /// Whether the remote desktop follows the pane. On: its size at the Mac's
  /// backing scale (1× on a slow link) and, where the server can, the desktop's
  /// UI scale to match. Off: nothing is sent; if this viewer changed the size or
  /// scale, they're put back. Only for sessions that resize their desktop.
  public var supportsDynamicResolution: Bool { session.resizesDesktop }
  public private(set) var dynamicResolution = false
  /// Sets the desktop's UI scale on the server (`setScale`, 851-2339); nil when it can't.
  var setDesktopScale: (@MainActor (Int) async -> Void)?
  /// The size the desktop was provisioned at (the server's `defaultWidth/Height`).
  public var defaultDesktopSize: (width: Int, height: Int)?
  /// The desktop can draw its UI at 2× (the server lists scale 2, 851-2339). Without it a
  /// 2× framebuffer would only make everything half size, so the pane stays at 1× pixels.
  public var desktopCanScale = false
  private var paneSize: (points: CGSize, backingScale: CGFloat)?
  private var resolution = ScreenSharingDynamicResolution()
  private var changedDesktop = false
  private var appliedScale: Int?

  public func setDynamicResolution(_ enabled: Bool) {
    guard enabled != dynamicResolution else { return }
    dynamicResolution = enabled
    applyResolution()
  }

  /// Sends what the current mode needs; also re-checked every second, as the link estimate moves.
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
    clipboard = session.clipboard.map { ScreenSharingViewerClipboard(channel: $0) }
    channel?.onMessage = { [weak self] in self?.emit(.message($0)) }
    channel?.onAvailabilityChanged = { [weak self] in self?.emit(.availability($0)) }
    forwarder.onLost = { [weak self] reason in
      self?.surface.endInput()
      self?.emit(.inputLost(reason))
    }
    surface.onInput = { [weak forwarder] in forwarder?.forward($0) }
    surface.onInputReleased = { [weak self] in
      guard let self else { return }
      self.forwarder.end()
      self.emit(.inputLost(self.surface.inputFailureMessage))
    }
    // Backends that report the pointer separately (VNC) draw it locally (851-2311).
    session.onCursorChanged = { [weak surface] in surface?.showRemoteCursor($0) }
    // With Dynamic Resolution on, a desktop that can resize follows the pane (851-2314, 851-2340).
    surface.onSizeChanged = { [weak self] size, scale in
      self?.paneSize = (size, scale)
      self?.applyResolution()
    }
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
        // The link estimate moves; a Retina pane may step between 1× and 2× (with hysteresis).
        if self.dynamicResolution { self.applyResolution() }
        if self.session.failure != nil, !self.reportedFailure {
          self.reportedFailure = true
          self.emit(.sessionFailed("Video decoding failed. Reconnect before controlling."))
        }
      }
    }
    // Statistics callbacks must never delay the lease's heartbeats, which run on their own timer.
    diagnosticsTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        if let self, self.presented {
          let statistics = await self.session.statistics()
          guard !Task.isCancelled else { return }
          self.diagnostics.update(
            metrics: self.session.metrics.snapshot(), statistics: statistics,
            now: ProcessInfo.processInfo.systemUptime)
        }
      }
    }
    ScreenSharingEndpointRegistry.shared.register(self)
  }

  // MARK: Control plane, addressed through ScreenSharingEndpointClient

  /// A stream that opens with the channel's current availability and then
  /// carries every control event until the endpoint closes.
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

  /// Begins capturing input on the surface and forwarding it under `lease`;
  /// returns the surface's failure message when capture is refused.
  func beginInput(lease: UUID) -> String? {
    guard surface.beginInput() else { return surface.inputFailureMessage }
    forwarder.begin(lease: lease)
    return nil
  }

  func endInput() {
    forwarder.end()
    surface.endInput()
  }

  /// The fill the surface paints around the remote display; the pane keeps it
  /// on the app's own surface color instead of black bars.
  public func letterbox(_ color: NSColor) { surface.setLetterboxColor(color) }

  private func emit(_ event: ScreenSharingControlEvent) {
    guard !closed else { return }
    for continuation in subscribers.values { continuation.yield(event) }
  }

  /// Terminal and idempotent: releases a held lease on the wire, stops input,
  /// the ticks and the surface, ends every control-event stream, then closes
  /// the session (which clears its mailbox and channels).
  func close() {
    guard !closed else { return }
    closed = true
    ScreenSharingEndpointRegistry.shared.unregister(id)
    if let lease = forwarder.lease { _ = channel?.send(.release(lease: lease)) }
    endInput()
    clipboard?.close()
    tickTask?.cancel(); tickTask = nil
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
