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
    // A remote desktop that can resize follows the pane (VNC ExtendedDesktopSize, 851-2314).
    surface.onSizeChanged = { [weak session] size in
      session?.requestDesktopSize(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
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
