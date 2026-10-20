import AppKit
import CodevisorCore
import Foundation
import Metal
import Observation
import ScreenSharing

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
    case cursorMoved(sessionID: String, point: CGPoint, at: TimeInterval)
    case cursorHidden(sessionID: String)
    case expireCursors(now: TimeInterval)
    case windowFrameChanged(sessionID: String, windowID: CGWindowID, frame: CGRect)
    case windowVisibilityChanged(sessionID: String, windowID: CGWindowID, visibility: ComputerUseWindowVisibility)
    case idled(sessionID: String)
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
      let knownVisibility = sameWindow ? previous?.windowVisibility : nil
      activities[key] = ComputerUseLivePreview.Activity(
        sessionID: key,
        bridgeSessionID: sessionID,
        appName: appName,
        pid: pid,
        windowID: windowID,
        windowFrame: windowFrame,
        colorIndex: colorIndex,
        cursor: sameWindow ? previous?.cursor : nil,
        cursorExpiresAt: sameWindow ? previous?.cursorExpiresAt : nil,
        state: .active,
        windowVisibility: knownVisibility ?? .visible
      )
    case .cursorMoved(let sessionID, let point, let now):
      let key = Self.key(sessionID)
      guard var activity = activities[key], activity.state == .active else { return }
      activity.cursor = computerUseNormalizedCursor(point: point, in: activity.windowFrame)
      activity.cursorExpiresAt = activity.cursor == nil ? nil : now + 2
      activities[key] = activity
    case .cursorHidden(let sessionID):
      let key = Self.key(sessionID)
      guard var activity = activities[key] else { return }
      activity.cursor = nil
      activity.cursorExpiresAt = nil
      activities[key] = activity
    case .expireCursors(let now):
      for (key, var activity) in activities {
        guard let deadline = activity.cursorExpiresAt, now >= deadline else { continue }
        activity.cursor = nil
        activity.cursorExpiresAt = nil
        activities[key] = activity
      }
    case .windowFrameChanged(let sessionID, let windowID, let frame):
      let key = Self.key(sessionID)
      guard var activity = activities[key], activity.windowID == windowID,
        activity.windowFrame != frame
      else { return }
      activity.windowFrame = frame
      activity.cursor = nil
      activity.cursorExpiresAt = nil
      activities[key] = activity
    case .windowVisibilityChanged(let sessionID, let windowID, let visibility):
      let key = Self.key(sessionID)
      guard var activity = activities[key], activity.windowID == windowID else { return }
      activity.windowVisibility = visibility
      activities[key] = activity
    case .idled(let sessionID):
      let key = Self.key(sessionID)
      guard var activity = activities[key], activity.state == .active else { return }
      activity.state = .idle
      activity.cursor = nil
      activity.cursorExpiresAt = nil
      activities[key] = activity
    case .stopped(let sessionID, let pid):
      let key = Self.key(sessionID)
      guard var activity = activities[key], pid == nil || activity.pid == pid else { return }
      activity.state = .stopped
      activity.cursor = nil
      activity.cursorExpiresAt = nil
      activities[key] = activity
    case .terminated(let pid):
      for (key, var activity) in activities where activity.pid == pid {
        activity.state = .stopped
        activity.cursor = nil
        activity.cursorExpiresAt = nil
        activities[key] = activity
      }
    case .removeAll:
      activities.removeAll()
    }
  }
}

func computerUseNormalizedCursor(point: CGPoint, in frame: CGRect) -> CGPoint? {
  guard frame.width > 0, frame.height > 0 else { return nil }
  let normalized = CGPoint(
    x: (point.x - frame.minX) / frame.width,
    y: (point.y - frame.minY) / frame.height
  )
  guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return nil }
  return normalized
}

@MainActor
@Observable
public final class ComputerUseLivePreview {
  public static let shared = ComputerUseLivePreview()

  public enum State: Equatable, Sendable { case active, idle, stopped }

  public struct Activity: Equatable, Sendable {
    public let sessionID: String
    let bridgeSessionID: String
    public let appName: String
    public let pid: pid_t
    public let windowID: CGWindowID?
    public internal(set) var windowFrame: CGRect
    let colorIndex: Int
    public internal(set) var cursor: CGPoint?
    var cursorExpiresAt: TimeInterval? = nil
    public internal(set) var state: State
    public internal(set) var windowVisibility: ComputerUseWindowVisibility = .visible

    public var tint: NSColor { ComputerUseCursorPalette.color(at: colorIndex) }
    public var windowNotice: String? { windowVisibility.notice(appName: appName) }
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
    var next = ledger
    next.apply(event)
    guard next != ledger else { return }
    ledger = next
    onChange.values.forEach { $0() }
  }

  @ObservationIgnored private var onChange: [UUID: () -> Void] = [:]

  func observe(_ handler: @escaping () -> Void) -> UUID {
    let token = UUID()
    onChange[token] = handler
    return token
  }

  func stopObserving(_ token: UUID) {
    onChange.removeValue(forKey: token)
  }

  public static func replace(
    _ viewer: ComputerUseLivePreviewViewer?,
    with make: () -> ComputerUseLivePreviewViewer?
  ) -> ComputerUseLivePreviewViewer? {
    viewer?.detach()
    return make()
  }

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
    let relay = ComputerUseWindowContentRelay()
    let sink = ComputerUseMailboxSink(mailbox: mailbox) { content in
      Task { @MainActor in relay.viewer?.update(windowContent: content) }
    }
    let token = attachSink(sessionID: bridgeSessionID, sink: sink)
    let viewer = ComputerUseLivePreviewViewer(title: activity.appName, phase: .live) { [weak self] in
      self?.detachSink(sessionID: bridgeSessionID, token: token)
    }
    relay.viewer = viewer
    viewer.onDisplayDimension = { dimension in
      guard abs(sink.requestedDimension - dimension) >= 1 else { return }
      sink.requestedDimension = dimension
      ComputerUseNativeSharing.shared.requestedDimensionChanged(sessionID: bridgeSessionID)
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
      ComputerUsePresentationState.shared.touch(sessionID: sessionID)
    }
  }
}

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
  public private(set) var frameSize: CGSize?
  public private(set) var windowContent: ComputerUseWindowContent?
  public private(set) var notice: String?
  @ObservationIgnored public var prefersFastPolling = false
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
  public func update(title: String) { self.title = title }
  func update(notice: String?) { self.notice = notice }
  func update(windowContent: ComputerUseWindowContent) {
    guard !isDetached else { return }
    self.windowContent = windowContent
  }

  @ObservationIgnored var onDisplayDimension: ((CGFloat) -> Void)?

  public func setDisplaySize(_ size: CGSize, backingScale: CGFloat) {
    guard !isDetached else { return }
    onDisplayDimension?(max(size.width, size.height) * max(1, backingScale))
  }

  public func setBackgroundColor(_ color: NSColor) {
    background = color
    surface?.setLetterboxColor(color)
  }

  public func detach() {
    guard !isDetached else { return }
    isDetached = true
    install(nil)
    let onDetach = onDetach
    self.onDetach = nil
    onDetach?()
  }
}

final class ComputerUseLivePreviewContainer: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class ComputerUseLivePreviewSurface: NSView, ScreenSharingViewerSurface {
  private let metal: ScreenSharingMetalView
  var onFrameSize: ((CGSize) -> Void)?
  var onPresented: (() -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  var onInput: ((ScreenSharingInputEvent) -> Void)?
  var onInputReleased: (() -> Void)?
  var onKeyboardReturned: (() -> Void)?
  var inputFailureMessage: String? { "This preview is view-only." }
  var capturesSystemShortcuts: Bool { false }
  var dropsInjectedInput = true
  var view: NSView { self }

  init(mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics) throws {
    metal = try ScreenSharingMetalView(
      mailbox: mailbox, metrics: metrics, renderOnArrival: true, offMainPreparation: true)
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

@MainActor
private final class ComputerUseWindowContentRelay: Sendable {
  weak var viewer: ComputerUseLivePreviewViewer?
}
