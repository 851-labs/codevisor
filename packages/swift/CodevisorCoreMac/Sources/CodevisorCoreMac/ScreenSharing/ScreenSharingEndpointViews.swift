import AppKit
import ScreenSharing

@MainActor
final class ScreenSharingEndpointViews {
  typealias Make = ScreenSharingSurfaceFactory

  struct Events {
    var input: (ScreenSharingInputEvent) -> Void = { _ in }
    var inputReleased: (String?) -> Void = { _ in }
    var sizeChanged: () -> Void = {}
    var screenChanged: () -> Void = {}
    var viewResized: (UUID) -> Void = { _ in }
    var focusChanged: (UUID, Bool) -> Void = { _, _ in }
    var keyboardReturned: (UUID) -> Void = { _ in }
  }

  private struct Shown {
    let surface: any ScreenSharingViewerSurface
    let metrics: ScreenSharingMetrics?
    var size: (points: CGSize, backingScale: CGFloat)?
    var screenShowsHighDynamicRange = false
  }

  var events = Events()
  var dropsInjectedInput = false {
    didSet { for shown in views.values { shown.surface.dropsInjectedInput = dropsInjectedInput } }
  }
  var localShortcuts: Set<ScreenSharingLocalShortcutGroup> = [] {
    didSet { for shown in views.values { shown.surface.localShortcuts = localShortcuts } }
  }
  private(set) var active: UUID?
  private(set) var driver: UUID?
  private var views: [UUID: Shown] = [:]
  private var videoShowsPointer = true
  private let frames: ScreenSharingFrameMailbox
  private let timeline: ScreenSharingFrameTimeline
  private let make: Make?

  init(frames: ScreenSharingFrameMailbox, timeline: ScreenSharingFrameTimeline, make: Make?) {
    self.frames = frames
    self.timeline = timeline
    self.make = make
  }

  var controlled: (any ScreenSharingViewerSurface)? { active.flatMap { views[$0]?.surface } }
  var size: (points: CGSize, backingScale: CGFloat)? { driver.flatMap { views[$0]?.size } }
  var screenShowsHighDynamicRange: Bool { driver.flatMap { views[$0]?.screenShowsHighDynamicRange } ?? false }

  var measured: ScreenSharingMetrics.Snapshot? {
    (driver.flatMap { views[$0] } ?? views.values.first)?.metrics?.snapshot()
  }

  func size(of id: UUID) -> CGSize? { views[id]?.size?.points }

  func adopt(_ surface: any ScreenSharingViewerSurface, as id: UUID) {
    views[id] = Shown(surface: surface, metrics: nil)
    wire(surface, as: id)
    activate(id)
    drive(with: id)
  }

  func view(for id: UUID) -> NSView? {
    if let existing = views[id] { return existing.surface.view }
    guard let make else { return nil }

    let metrics = ScreenSharingMetrics(timeline: timeline)
    guard let surface = try? make(frames.tap(id), metrics) else {
      frames.untap(id)
      return nil
    }
    views[id] = Shown(surface: surface, metrics: metrics)
    wire(surface, as: id)
    return surface.view
  }

  func remove(_ id: UUID) {
    guard let removed = views.removeValue(forKey: id) else { return }

    if active == id { activate(nil) }
    if driver == id { drive(with: nil) }
    removed.surface.stop()
    frames.untap(id)
  }

  func activate(_ id: UUID?) {
    active = id
    if let id { _ = view(for: id) }
  }

  func drive(with id: UUID?) {
    guard id != driver else { return }

    let (previousSize, showedHighDynamicRange) = (size, screenShowsHighDynamicRange)
    driver = id
    if let size, size.points != previousSize?.points || size.backingScale != previousSize?.backingScale {
      events.sizeChanged()
    }
    if screenShowsHighDynamicRange != showedHighDynamicRange { events.screenChanged() }
  }

  func hasKeyboardFocus(in id: UUID?) -> Bool {
    guard let view = id.flatMap({ views[$0]?.surface.view }), let window = view.window else { return false }

    return window.firstResponder === view
  }

  func focus(_ id: UUID) {
    guard let view = views[id]?.surface.view, let window = view.window else { return }

    window.makeFirstResponder(view)
  }

  func letterbox(_ color: NSColor, in id: UUID) {
    views[id]?.surface.setLetterboxColor(color)
  }

  func setVideoShowsPointer(_ shows: Bool) {
    videoShowsPointer = shows
    for shown in views.values { shown.surface.setVideoShowsPointer(shows) }
  }

  func showRemoteCursor(_ update: ScreenSharingCursorUpdate) {
    for shown in views.values { shown.surface.showRemoteCursor(update) }
  }

  func stop() {
    for (id, shown) in views {
      shown.surface.stop()
      frames.untap(id)
    }
    views = [:]
    active = nil
    driver = nil
  }

  private func wire(_ surface: any ScreenSharingViewerSurface, as id: UUID) {
    surface.dropsInjectedInput = dropsInjectedInput
    surface.localShortcuts = localShortcuts
    surface.setVideoShowsPointer(videoShowsPointer)
    surface.onKeyboardReturned = { [weak self] in self?.events.keyboardReturned(id) }
    surface.onFocusChanged = { [weak self] in self?.events.focusChanged(id, $0) }
    surface.onInput = { [weak self] in
      guard let self, self.active == id else { return }

      self.events.input($0)
    }
    surface.onInputReleased = { [weak self, weak surface] in
      guard let self, self.active == id else { return }

      self.events.inputReleased(surface?.inputFailureMessage)
    }
    surface.onSizeChanged = { [weak self] size, scale in self?.resized(id, to: (size, scale)) }
    surface.onScreenHighDynamicRangeChanged = { [weak self] in self?.screenChanged(id, showsHighDynamicRange: $0) }
  }

  private func resized(_ id: UUID, to size: (points: CGSize, backingScale: CGFloat)) {
    views[id]?.size = size
    if driver == id { events.sizeChanged() }
    events.viewResized(id)
  }

  private func screenChanged(_ id: UUID, showsHighDynamicRange: Bool) {
    views[id]?.screenShowsHighDynamicRange = showsHighDynamicRange
    if driver == id { events.screenChanged() }
  }
}
