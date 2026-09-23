import AppKit
import CodevisorCore
import Foundation
import Metal
import Observation
import ScreenSharing

// MARK: - Geometry

/// Aspect-fits a frame into the preview card's bounds.
public func computerUseLivePreviewSize(
  frameSize: CGSize,
  maxWidth: CGFloat,
  maxHeight: CGFloat
) -> CGSize {
  guard frameSize.width > 0, frameSize.height > 0, maxWidth > 0, maxHeight > 0 else {
    return CGSize(width: maxWidth, height: maxWidth * 10 / 16)
  }
  let scale = min(maxWidth / frameSize.width, maxHeight / frameSize.height)
  return CGSize(
    width: (frameSize.width * scale).rounded(),
    height: (frameSize.height * scale).rounded()
  )
}

// MARK: - Ledger

/// What the agent of each chat session is controlling. Pure so transitions
/// test without AppKit or ScreenCaptureKit.
struct ComputerUseLivePreviewLedger: Equatable {
  enum Event: Equatable {
    case activated(
      sessionID: String,
      appName: String,
      pid: pid_t,
      windowID: CGWindowID?,
      windowFrame: CGRect,
      colorIndex: Int
    )
    /// `point` is in the same screen coordinates as `windowFrame`.
    case cursorMoved(sessionID: String, point: CGPoint)
    /// The controlled window moved or resized between tool calls.
    case windowFrameChanged(sessionID: String, windowID: CGWindowID, frame: CGRect)
    case idled(sessionID: String)
    /// A nil pid stops the session whatever it controls.
    case stopped(sessionID: String, pid: pid_t?)
    case terminated(pid: pid_t)
    case removeAll
  }

  private(set) var activities: [String: ComputerUseLivePreview.Activity] = [:]

  static func key(_ sessionID: String) -> String { sessionID.lowercased() }

  mutating func apply(_ event: Event) {
    switch event {
    case .activated(let sessionID, let appName, let pid, let windowID, let windowFrame, let colorIndex):
      let key = Self.key(sessionID)
      let previous = activities[key]
      let sameWindow = previous?.windowID == windowID && previous?.pid == pid
      activities[key] = ComputerUseLivePreview.Activity(
        sessionID: key,
        bridgeSessionID: sessionID,
        appName: appName,
        pid: pid,
        windowID: windowID,
        windowFrame: windowFrame,
        colorIndex: colorIndex,
        cursor: sameWindow ? previous?.cursor : nil,
        state: .active
      )
    case .cursorMoved(let sessionID, let point):
      let key = Self.key(sessionID)
      guard var activity = activities[key], activity.state == .active else { return }
      activity.cursor = computerUseNormalizedCursor(point: point, in: activity.windowFrame)
      activities[key] = activity
    case .windowFrameChanged(let sessionID, let windowID, let frame):
      let key = Self.key(sessionID)
      guard var activity = activities[key], activity.windowID == windowID,
        activity.windowFrame != frame
      else { return }
      activity.windowFrame = frame
      // A position normalized against the old frame no longer lines up.
      activity.cursor = nil
      activities[key] = activity
    case .idled(let sessionID):
      let key = Self.key(sessionID)
      guard var activity = activities[key], activity.state == .active else { return }
      activity.state = .idle
      activities[key] = activity
    case .stopped(let sessionID, let pid):
      let key = Self.key(sessionID)
      guard var activity = activities[key], pid == nil || activity.pid == pid else { return }
      activity.state = .stopped
      activities[key] = activity
    case .terminated(let pid):
      for (key, var activity) in activities where activity.pid == pid {
        activity.state = .stopped
        activities[key] = activity
      }
    case .removeAll:
      activities.removeAll()
    }
  }
}

/// A point inside the window as a 0…1 fraction of its frame, or nil outside.
func computerUseNormalizedCursor(point: CGPoint, in frame: CGRect) -> CGPoint? {
  guard frame.width > 0, frame.height > 0 else { return nil }
  let normalized = CGPoint(
    x: (point.x - frame.minX) / frame.width,
    y: (point.y - frame.minY) / frame.height
  )
  guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return nil }
  return normalized
}

// MARK: - Facade

/// The app-facing view of Computer Use activity per chat session, and the
/// source of live previews of the window each agent controls.
@MainActor
@Observable
public final class ComputerUseLivePreview {
  public static let shared = ComputerUseLivePreview()

  public enum State: Equatable, Sendable { case active, idle, stopped }

  public struct Activity: Equatable, Sendable {
    /// Lowercased chat session id.
    public let sessionID: String
    /// The id exactly as the bridge received it.
    let bridgeSessionID: String
    public let appName: String
    public let pid: pid_t
    public let windowID: CGWindowID?
    /// Screen points, top-left origin.
    public internal(set) var windowFrame: CGRect
    let colorIndex: Int
    /// The agent cursor as a 0…1 fraction of the window, when known.
    public internal(set) var cursor: CGPoint?
    public internal(set) var state: State

    public var tint: NSColor { ComputerUseCursorPalette.color(at: colorIndex) }
  }

  private var ledger = ComputerUseLivePreviewLedger()

  public var activities: [String: Activity] { ledger.activities }

  public func activity(forChatSession id: UUID) -> Activity? {
    ledger.activities[ComputerUseLivePreviewLedger.key(id.uuidString)]
  }

  func activity(forSessionID id: String) -> Activity? {
    ledger.activities[ComputerUseLivePreviewLedger.key(id)]
  }

  func apply(_ event: ComputerUseLivePreviewLedger.Event) {
    let before = ledger
    ledger.apply(event)
    guard ledger != before else { return }
    onChange.values.forEach { $0() }
  }

  /// Internal observers (the remote host) that are not SwiftUI.
  @ObservationIgnored private var onChange: [UUID: () -> Void] = [:]

  func observe(_ handler: @escaping () -> Void) -> UUID {
    let token = UUID()
    onChange[token] = handler
    return token
  }

  func stopObserving(_ token: UUID) {
    onChange.removeValue(forKey: token)
  }

  /// A viewer of the window the chat's agent controls on this Mac, or nil
  /// when there is no activity or Metal is unavailable. Call `detach()`.
  public func makeLocalViewer(chatSession id: UUID) -> ComputerUseLivePreviewViewer? {
    guard let activity = activity(forChatSession: id) else { return nil }
    let mailbox = ScreenSharingFrameMailbox()
    let surface: ComputerUseLivePreviewSurface
    do {
      surface = try ComputerUseLivePreviewSurface(mailbox: mailbox, metrics: ScreenSharingMetrics())
    } catch {
      Log.computerUse.error(
        "Unable to create a Computer Use live preview: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
    let bridgeSessionID = activity.bridgeSessionID
    let token = attachSink(sessionID: bridgeSessionID, sink: ComputerUseMailboxSink(mailbox: mailbox))
    let viewer = ComputerUseLivePreviewViewer(title: activity.appName, phase: .live) { [weak self] in
      self?.detachSink(sessionID: bridgeSessionID, token: token)
    }
    viewer.install(surface)
    return viewer
  }

  func attachSink(sessionID: String, sink: any ComputerUseFrameSink) -> UUID {
    let token = UUID()
    ComputerUseNativeSharing.shared.attachSink(sessionID: sessionID, token: token, sink: sink)
    return token
  }

  func detachSink(sessionID: String, token: UUID) {
    ComputerUseNativeSharing.shared.detachSink(sessionID: sessionID, token: token)
    if !ComputerUseNativeSharing.shared.hasSinks(sessionID: sessionID) {
      // A session kept alive only by its viewers gets a full idle grace
      // from now, rather than an immediate release.
      ComputerUsePresentationState.shared.touch(sessionID: sessionID)
    }
  }
}

// MARK: - Viewer

@MainActor
@Observable
public final class ComputerUseLivePreviewViewer {
  public enum Phase: Equatable, Sendable {
    case searching
    case connecting
    case live
    case reconnecting
    case stopped(String)
  }

  public private(set) var phase: Phase
  public private(set) var title: String
  /// The latest frame's pixel size; nil before the first frame.
  public private(set) var frameSize: CGSize?
  /// Remote viewers look for the agent's activity more often while the
  /// chat's turn is running. Ignored by local viewers.
  @ObservationIgnored public var prefersFastPolling = false
  /// Hosts the current surface; stable for the viewer's lifetime so a
  /// remote reconnect can swap surfaces underneath SwiftUI.
  @ObservationIgnored public let view: NSView = ComputerUseLivePreviewContainer()

  @ObservationIgnored private var surface: ComputerUseLivePreviewSurface?
  @ObservationIgnored private var background = NSColor.black
  @ObservationIgnored private var onDetach: (() -> Void)?
  @ObservationIgnored private(set) var isDetached = false

  init(title: String, phase: Phase, onDetach: (() -> Void)?) {
    self.title = title
    self.phase = phase
    self.onDetach = onDetach
  }

  func install(_ surface: ComputerUseLivePreviewSurface?) {
    guard surface == nil || !isDetached else {
      surface?.stop()
      return
    }
    self.surface?.stop()
    self.surface?.removeFromSuperview()
    self.surface = surface
    frameSize = nil
    guard let surface else { return }
    surface.setLetterboxColor(background)
    surface.onFrameSize = { [weak self] size in self?.frameSize = size }
    surface.frame = view.bounds
    surface.autoresizingMask = [.width, .height]
    view.addSubview(surface)
  }

  func update(phase: Phase) { self.phase = phase }
  func update(title: String) { self.title = title }

  public func setBackgroundColor(_ color: NSColor) {
    background = color
    surface?.setLetterboxColor(color)
  }

  /// Idempotent. Stops rendering and releases the frame source.
  public func detach() {
    guard !isDetached else { return }
    isDetached = true
    install(nil)
    let onDetach = onDetach
    self.onDetach = nil
    onDetach?()
  }
}

/// Never takes input: the card around it handles clicks.
final class ComputerUseLivePreviewContainer: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A view-only video surface: renders a mailbox, captures no input. Also
/// the surface the remote viewer runner renders into.
@MainActor
final class ComputerUseLivePreviewSurface: NSView, ScreenSharingViewerSurface {
  private let metal: ScreenSharingMetalView
  var onFrameSize: ((CGSize) -> Void)?
  var onPresented: (() -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  var onInput: ((ScreenSharingInputEvent) -> Void)?
  var onInputReleased: (() -> Void)?
  var inputFailureMessage: String? { "This preview is view-only." }
  var view: NSView { self }

  init(mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics) throws {
    metal = try ScreenSharingMetalView(mailbox: mailbox, metrics: metrics, renderOnArrival: true)
    super.init(frame: .zero)
    wantsLayer = true
    metal.frame = bounds
    metal.autoresizingMask = [.width, .height]
    addSubview(metal)
    metal.onFrameSize = { [weak self] size in self?.onFrameSize?(size) }
    metal.onPresented = { [weak self] _ in self?.onPresented?() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func beginInput() -> Bool { false }
  func endInput() {}
  func stop() { metal.stop() }

  func setLetterboxColor(_ color: NSColor) {
    guard let rgb = color.usingColorSpace(.sRGB) else { return }
    metal.clearColor = MTLClearColorMake(
      rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
  }
}
