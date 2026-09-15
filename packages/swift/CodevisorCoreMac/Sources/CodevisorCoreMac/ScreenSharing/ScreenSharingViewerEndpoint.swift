import AppKit
import CodevisorScreenSharing
import OSLog

/// The AppKit half of a viewer endpoint: the view the pane mounts, its input
/// capture, and the signal that a frame reached the screen. The product
/// surface is `ScreenSharingVideoSurface`; tests supply a controlled one.
@MainActor
protocol ScreenSharingViewerSurface: AnyObject {
  var view: NSView { get }
  var fitToWindow: Bool { get set }
  /// Fired for every presentation; the endpoint reports only the first.
  var onPresented: (() -> Void)? { get set }
  var onFocusChanged: ((Bool) -> Void)? { get set }
  var onInput: ((ScreenSharingInputEvent) -> Void)? { get set }
  /// The surface lost the ability to capture input (event tap interrupted, focus refused).
  var onInputReleased: (() -> Void)? { get set }
  var inputFailureMessage: String? { get }
  func beginInput() -> Bool
  func endInput()
  func stop()
}

/// One connected viewing endpoint as the pane sees it, for any backend: the
/// surface rendering the session's frames, the control lease driven over the
/// session's control channel, the explicit clipboard transfer, and the
/// diagnostics sampled from the session. Equal by identity — the reducer keeps
/// the live endpoint in state and replaces it whole on reconnection.
///
/// Control, clipboard and diagnostics stay `@Observable` objects: they are
/// data-plane state (1 Hz ticks, input events, chunk transfers) that the pane
/// observes directly rather than routing through actions.
@MainActor
public final class ScreenSharingViewerEndpoint: Equatable {
  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")
  public let capabilities: ScreenSharingCapabilities
  /// The lease-based control protocol is available on this session.
  public var supportsControl: Bool { capabilities.contains(.control) }
  /// The explicit text clipboard protocol is available on this session.
  public var supportsClipboard: Bool { capabilities.contains(.clipboard) }
  public var view: NSView { surface.view }
  public let control: ScreenSharingViewerControl
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
  private var controlTask: Task<Void, Never>?
  private var diagnosticsTask: Task<Void, Never>?
  private var presented = false
  private var closed = false

  init(session: any ScreenSharingViewingSession, surface: any ScreenSharingViewerSurface) {
    self.session = session
    self.surface = surface
    capabilities = session.capabilities
    if let channel = session.control {
      let control = ScreenSharingViewerControl(send: { [weak channel] in channel?.send($0) ?? false })
      channel.onMessage = { [weak control] in control?.receive($0) }
      channel.onAvailabilityChanged = { [weak control] in control?.setAvailable($0) }
      control.setAvailable(channel.isAvailable)
      self.control = control
    } else {
      // No control protocol on this session: the lease can never become available.
      control = ScreenSharingViewerControl(send: { _ in false })
    }
    clipboard = session.clipboard.map { ScreenSharingViewerClipboard(channel: $0) }
    control.onActiveChanged = { [weak self] active in
      guard let self else { return }
      if active {
        if !self.surface.beginInput() { self.control.release(reason: self.surface.inputFailureMessage) }
      } else {
        self.surface.endInput()
      }
    }
    surface.onInput = { [weak control] in control?.input($0) }
    surface.onInputReleased = { [weak control, weak surface] in control?.release(reason: surface?.inputFailureMessage) }
    surface.onPresented = { [weak self] in
      guard let self, !self.presented else { return }
      self.presented = true
      self.onReady?()
    }
    controlTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        self?.clipboard?.tick()
        if self?.failure != nil {
          self?.control.release(reason: "Video decoding failed. Reconnect before controlling.")
        } else {
          self?.control.tick()
        }
      }
    }
    // Statistics callbacks must never delay input lease heartbeats.
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
  }

  public func fit(_ enabled: Bool) { surface.fitToWindow = enabled }

  /// Terminal and idempotent: releases input, stops the ticks and the
  /// surface, then closes the session (which clears its mailbox and channels).
  func close() {
    guard !closed else { return }
    closed = true
    clipboard?.close()
    control.release()
    controlTask?.cancel(); controlTask = nil
    diagnosticsTask?.cancel(); diagnosticsTask = nil
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
