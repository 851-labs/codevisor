import AppKit
import CodevisorScreenSharing
import QuartzCore

/// Drawing window and view shared by the visible desktop workload and the
/// owned-window capture diagnostic. Counters describe AppKit draw calls and
/// received events, never claimed source/display presentation times.
@MainActor
final class WorkloadWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  // The diagnostic may need a 4K backing surface on a smaller physical display.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct WorkloadDraw: Encodable {
  let code: Int
  let startedAtSeconds: Double
}

struct WorkloadEvent: Encodable {
  let kind: String
  let response: Int
  let elapsedSeconds: Double
}

@MainActor
final class WorkloadView: NSView {
  let painter: ProbeDesktopPainter
  let fps: Int
  private var timer: Timer?
  private(set) var startedAt = 0.0
  private(set) var drawCalls = 0
  private(set) var sequence = 0
  private(set) var responses = 0
  private(set) var events: [WorkloadEvent] = []
  private let recordDrawTimes: Bool
  /// Bounded first-draw-start record (shared semantics with the image-age analyzer).
  private var drawRecord = ScreenSharingDrawTimestampRecord()
  var drawSamples: [WorkloadDraw] {
    drawRecord.samples.map { WorkloadDraw(code: $0.code, startedAtSeconds: $0.startedAtSeconds) }
  }
  var drawSamplesTruncated: Bool { drawRecord.truncated }
  /// Core Animation time at which the first `draw(_:)` call started, and the
  /// time at which that call returned. Neither is a presentation time: the
  /// window server displays the drawn content later.
  private(set) var firstDrawStartedAt: Double?
  private(set) var firstDrawCompletedAt: Double?
  /// Called once, on the main actor, right after the first draw call returns.
  var onFirstDraw: (() -> Void)?
  /// Frozen at a pause: later redraws keep the same code (see the sequence type).
  private(set) var codes: ScreenSharingWorkloadSequence?
  var isPaused: Bool { codes?.isFrozen ?? false }
  override var acceptsFirstResponder: Bool { true }
  override var isOpaque: Bool { true }

  init(painter: ProbeDesktopPainter, recordDrawTimes: Bool) {
    self.painter = painter
    self.fps = painter.fps
    self.recordDrawTimes = recordDrawTimes
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  func start() {
    startedAt = CACurrentMediaTime()
    codes = ScreenSharingWorkloadSequence(framesPerSecond: fps, startedAtSeconds: startedAt)
    let timer = Timer(
      timeInterval: 1 / Double(fps), target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    needsDisplay = true
  }

  func stop() { timer?.invalidate(); timer = nil }

  /// Stops the animation and freezes the frame code at the LAST DRAWN code —
  /// not a newly time-derived one — so a pause between frames holds what was
  /// actually rendered last, through any later redraw. Distinct from stopping
  /// a capture stream.
  func pause() {
    stop()
    codes?.freezeAtLastDrawn(atSeconds: CACurrentMediaTime())
  }

  /// The frozen code after a pause; equals `sequence` (the last drawn code).
  var frozenCode: Int? { codes?.frozenCode }

  @objc private func tick() { needsDisplay = true }

  override func mouseDown(with event: NSEvent) { respond(kind: "mouseDown") }
  override func keyDown(with event: NSEvent) {
    if !event.isARepeat { respond(kind: "keyDown") }
  }

  private func respond(kind: String) {
    responses += 1
    if events.count < 128 {
      events.append(WorkloadEvent(kind: kind, response: responses, elapsedSeconds: CACurrentMediaTime() - startedAt))
    }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard startedAt > 0, let context = NSGraphicsContext.current?.cgContext else { return }
    drawCalls += 1
    let drawStarted = CACurrentMediaTime()
    // A paused view redraws its frozen code unchanged (window server
    // requests only); it never advances the content. `sequence` is the last
    // DRAWN code, not evidence of what the display showed.
    sequence = codes?.drawn(atSeconds: drawStarted) ?? 0
    if recordDrawTimes { drawRecord.record(code: sequence, startedAtSeconds: drawStarted) }
    painter.draw(in: context, bounds: bounds, sequence: sequence, responses: responses)
    if firstDrawStartedAt == nil {
      firstDrawStartedAt = drawStarted
      firstDrawCompletedAt = CACurrentMediaTime()
      let callback = onFirstDraw
      onFirstDraw = nil
      callback?()
    }
  }
}
