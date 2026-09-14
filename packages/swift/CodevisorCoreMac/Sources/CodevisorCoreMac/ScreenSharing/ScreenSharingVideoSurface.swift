import AppKit
import CodevisorClient
import CodevisorScreenSharing
import OSLog

@MainActor
final class ScreenSharingVideoSurface: NSView, ScreenSharingInputTarget {
  var onFocusChanged: ((Bool) -> Void)?
  let metal: ScreenSharingMetalView
  lazy var input = ScreenSharingInputSurface(view: self)
  private var tracking: NSTrackingArea?
  private static let remoteCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
  private let scroll = NSScrollView()
  private var videoSize = CGSize(width: 1920, height: 1080)
  var fitToWindow = true { didSet { needsLayout = true; metal.fitToWindow = fitToWindow } }

  /// `profile` nil (the default) keeps the product renderer exactly as it was: display-link drive, three drawables,
  /// main-actor preparation. The explicit profile forwards to the EXISTING worker/arrival2 initializer; no pacing,
  /// render-queue rewrite or auditing feature is added here.
  init(peer: ScreenSharingPeer, profile: ScreenSharingDiagnosticProfile? = nil) throws {
    metal = try ScreenSharingMetalView(
      mailbox: peer.mailbox, metrics: peer.metrics, renderOnArrival: profile?.renderOnArrival ?? false,
      maximumDrawableCount: profile?.maximumDrawableCount ?? 3,
      offMainPreparation: profile?.offMainPreparation ?? false)
    super.init(frame: .zero)
    scroll.drawsBackground = false
    scroll.autohidesScrollers = true
    scroll.documentView = metal
    addSubview(scroll)
    metal.onFrameSize = { [weak self] size in
      self?.videoSize = size
      self?.needsLayout = true
    }
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    scroll.frame = bounds
    scroll.hasHorizontalScroller = !fitToWindow
    scroll.hasVerticalScroller = !fitToWindow
    let viewport = scroll.contentSize
    let pixels = convertFromBacking(videoSize)
    metal.frame = CGRect(
      origin: .zero,
      size: fitToWindow
        ? viewport
        : CGSize(
          width: max(viewport.width, pixels.width), height: max(viewport.height, pixels.height)))
    window?.invalidateCursorRects(for: self)
  }
  override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
  /// Input first, then the renderer's terminal stop (arrival subscription,
  /// mailbox, cached frame and callbacks released; an in-flight submission
  /// keeps its buffers until the GPU completes it).
  func stop() { input.end(); metal.stop() }
  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { input.resume(); onFocusChanged?(true) }
    return accepted
  }
  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { input.suspend(); onFocusChanged?(false) }
    return accepted
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return input.active && hit != nil ? self : hit
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    tracking = area; addTrackingArea(area)
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    guard input.active else { return }
    let drawable = metal.convertToBacking(metal.bounds).size
    let scale = fitToWindow ? min(drawable.width / videoSize.width, drawable.height / videoSize.height) : 1
    let video = CGRect(
      x: (drawable.width - videoSize.width * scale) / 2,
      y: (drawable.height - videoSize.height * scale) / 2,
      width: videoSize.width * scale, height: videoSize.height * scale)
    let rect = convert(metal.convertFromBacking(video), from: metal).intersection(bounds)
    if !rect.isEmpty { addCursorRect(rect, cursor: Self.remoteCursor) }
  }
  func controlCursorChanged() {
    window?.invalidateCursorRects(for: self)
    if !input.active, NSCursor.current === Self.remoteCursor { NSCursor.arrow.set() }
  }
  override func cursorUpdate(with event: NSEvent) {
    if input.active, pointer(event, clamp: false) != nil { Self.remoteCursor.set() } else { NSCursor.arrow.set() }
  }
  override func mouseExited(with event: NSEvent) {
    if NSCursor.current === Self.remoteCursor { NSCursor.arrow.set() }
  }
  override func mouseEntered(with event: NSEvent) { cursorUpdate(with: event) }
  override func mouseMoved(with event: NSEvent) {
    if input.active { cursorUpdate(with: event) }
    input.mouse(event)
  }
  override func mouseDown(with event: NSEvent) { input.mouse(event) }
  override func mouseUp(with event: NSEvent) { input.mouse(event) }
  override func rightMouseDown(with event: NSEvent) { input.mouse(event) }
  override func rightMouseUp(with event: NSEvent) { input.mouse(event) }
  override func otherMouseDown(with event: NSEvent) { input.mouse(event) }
  override func otherMouseUp(with event: NSEvent) { input.mouse(event) }
  override func mouseDragged(with event: NSEvent) { input.mouse(event) }
  override func rightMouseDragged(with event: NSEvent) { input.mouse(event) }
  override func otherMouseDragged(with event: NSEvent) { input.mouse(event) }
  override func scrollWheel(with event: NSEvent) {
    if input.active { input.mouse(event) } else { super.scrollWheel(with: event) }
  }
  func pointer(_ event: NSEvent, clamp: Bool) -> ScreenSharingPointer? {
    let point = metal.convertToBacking(metal.convert(event.locationInWindow, from: nil))
    let size = metal.convertToBacking(metal.bounds).size
    return ScreenSharingVideoGeometry.pointer(
      x: point.x, y: metal.isFlipped ? point.y : size.height - point.y,
      surfaceWidth: size.width, surfaceHeight: size.height,
      videoWidth: videoSize.width, videoHeight: videoSize.height, fit: fitToWindow, clamp: clamp)
  }

}

@MainActor
protocol ScreenSharingViewingPeer: AnyObject {
  var view: NSView { get }
  var failure: String? { get }
  var control: ScreenSharingViewerControl { get }
  var clipboard: ScreenSharingViewerClipboard? { get }
  var diagnostics: ScreenSharingViewerDiagnostics { get }
  var onReady: (() -> Void)? { get set }
  var onConnectionChanged: ((String) -> Void)? { get set }
  var onFocusChanged: ((Bool) -> Void)? { get set }
  func offer() async throws -> String
  func accept(_ answer: String) async throws
  func fit(_ enabled: Bool)
  func close()
}

@MainActor
final class NativeScreenSharingViewingPeer: ScreenSharingViewingPeer {
  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")
  let peer: ScreenSharingPeer
  let surface: ScreenSharingVideoSurface
  let control: ScreenSharingViewerControl
  let clipboard: ScreenSharingViewerClipboard?
  let diagnostics = ScreenSharingViewerDiagnostics()
  private var controlTask: Task<Void, Never>?
  private var diagnosticsTask: Task<Void, Never>?
  var view: NSView { surface }
  var failure: String? { peer.metrics.snapshot().labels["decoderError"] }
  var onReady: (() -> Void)?
  var onConnectionChanged: ((String) -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  private var presented = false

  init(connectivity: ServerScreenSharingConnectivity? = nil) throws {
    // Parsed once per process (failures cached too), so both roles in this app process agree; an unknown value fails
    // here rather than selecting the candidate.
    let profile = try ScreenSharingDiagnosticProfile.process()
    // Trials are process-wide and irreversible: install (or prove already installed) BEFORE the peer exists. A
    // conflict with a selection already installed by the host role in this same app process throws here, so reaching
    // the next line means this profile's settings are the ones actually wired below.
    try ScreenSharingFieldTrials.process.install(profile: profile)
    let metrics = ScreenSharingMetrics()
    metrics.label("diagnosticProfileRequested", profile?.name ?? "none")
    metrics.label("diagnosticProfileActive", profile?.name ?? "none")
    if let profile {
      metrics.label(
        "diagnosticProfileRenderer",
        "arrival rendering, \(profile.maximumDrawableCount) drawables, off-main preparation")
    }
    peer = try ScreenSharingPeer(
      sending: false, configuration: .init(), metrics: metrics,
      connectivity: connectivity?.native())
    surface = try ScreenSharingVideoSurface(peer: peer, profile: profile)
    clipboard = ScreenSharingViewerClipboard(channel: peer.clipboard)
    let channel = peer.control
    control = ScreenSharingViewerControl(send: { [weak channel] in channel?.send($0) ?? false })
    channel.onMessage = { [weak control] in control?.receive($0) }
    channel.onAvailabilityChanged = { [weak control] in control?.setAvailable($0) }
    control.setAvailable(channel.isAvailable)
    control.onActiveChanged = { [weak self] active in
      guard let self else { return }
      if active {
        if !self.surface.input.begin() { self.control.release(reason: self.surface.input.failureMessage) }
      } else {
        self.surface.input.end()
      }
    }
    surface.onFocusChanged = { [weak self] in self?.onFocusChanged?($0) }
    surface.input.onInput = { [weak control] in control?.input($0) }
    surface.input.onRelease = { [weak control, weak input = surface.input] in
      control?.release(reason: input?.failureMessage)
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
          let statistics = await self.peer.statistics()
          guard !Task.isCancelled else { return }
          self.diagnostics.update(
            metrics: self.peer.metrics.snapshot(), statistics: statistics,
            now: ProcessInfo.processInfo.systemUptime)
        }
      }
    }
    peer.onConnectionChanged = { [weak self] in self?.onConnectionChanged?($0) }
    surface.metal.onPresented = { [weak self] _ in
      guard let self, !self.presented else { return }
      self.presented = true
      self.onReady?()
    }
  }
  func offer() async throws -> String { try await peer.makeDescription(offer: true).sdp }
  func accept(_ answer: String) async throws { try await peer.accept(.init(kind: "answer", sdp: answer)) }
  func fit(_ enabled: Bool) { surface.fitToWindow = enabled }
  func close() {
    guard !closed else { return }
    closed = true
    clipboard?.close()
    control.release(); controlTask?.cancel(); controlTask = nil
    diagnosticsTask?.cancel(); diagnosticsTask = nil
    let metrics = peer.metrics.snapshot()
    Self.logger.info(
      "Viewer ended: \(String(describing: metrics.counters), privacy: .public), \(String(describing: metrics.labels), privacy: .public), drawable \(String(describing: self.surface.metal.drawableSize), privacy: .public)"
    )
    onReady = nil; onConnectionChanged = nil; surface.stop(); peer.close()
  }
  private var closed = false
}
