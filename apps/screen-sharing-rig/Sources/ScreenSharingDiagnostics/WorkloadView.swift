import AppKit
import ScreenSharing
import QuartzCore

/// Drawing window and view shared by the visible desktop workload and the
/// owned-window capture diagnostic. Counters describe AppKit draw calls and
/// received events, never claimed source/display presentation times.
@MainActor
package final class WorkloadWindow: NSWindow {
  package override var canBecomeKey: Bool { true }
  package override var canBecomeMain: Bool { true }
  // The diagnostic may need a 4K backing surface on a smaller physical display.
  package override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

package struct WorkloadDraw: Encodable {
  package let code: Int
  package let startedAtSeconds: Double
}

package struct WorkloadEvent: Encodable {
  package let kind: String
  package let response: Int
  package let elapsedSeconds: Double
}

@MainActor
package final class WorkloadView: NSView {
  package let painter: ProbeDesktopPainter
  package let fps: Int
  private var timer: Timer?
  public private(set) var startedAt = 0.0
  public private(set) var drawCalls = 0
  public private(set) var sequence = 0
  public private(set) var responses = 0
  public private(set) var events: [WorkloadEvent] = []
  private let recordDrawTimes: Bool
  /// Bounded first-draw-start record (shared semantics with the image-age analyzer).
  private var drawRecord = ScreenSharingDrawTimestampRecord()
  package var drawSamples: [WorkloadDraw] {
    drawRecord.samples.map { WorkloadDraw(code: $0.code, startedAtSeconds: $0.startedAtSeconds) }
  }
  package var drawSamplesTruncated: Bool { drawRecord.truncated }
  /// Core Animation time at which the first `draw(_:)` call started, and the
  /// time at which that call returned. Neither is a presentation time: the
  /// window server displays the drawn content later.
  public private(set) var firstDrawStartedAt: Double?
  public private(set) var firstDrawCompletedAt: Double?
  /// Called once, on the main actor, right after the first draw call returns.
  package var onFirstDraw: (() -> Void)?
  /// Frozen at a pause: later redraws keep the same code (see the sequence type).
  public private(set) var codes: ScreenSharingWorkloadSequence?
  package var isPaused: Bool { codes?.isFrozen ?? false }
  package override var acceptsFirstResponder: Bool { true }
  /// The click that makes a key-able window key is otherwise swallowed by AppKit; the workload counts it.
  package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  package override var isOpaque: Bool { true }

  package init(painter: ProbeDesktopPainter, recordDrawTimes: Bool) {
    self.painter = painter
    self.fps = painter.fps
    self.recordDrawTimes = recordDrawTimes
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  package func start() {
    startedAt = CACurrentMediaTime()
    codes = ScreenSharingWorkloadSequence(framesPerSecond: fps, startedAtSeconds: startedAt)
    let timer = Timer(
      timeInterval: 1 / Double(fps), target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    needsDisplay = true
  }

  package func stop() { timer?.invalidate(); timer = nil }

  /// Stops the animation and freezes the frame code at the LAST DRAWN code —
  /// not a newly time-derived one — so a pause between frames holds what was
  /// actually rendered last, through any later redraw. Distinct from stopping
  /// a capture stream.
  package func pause() {
    stop()
    codes?.freezeAtLastDrawn(atSeconds: CACurrentMediaTime())
  }

  /// The frozen code after a pause; equals `sequence` (the last drawn code).
  package var frozenCode: Int? { codes?.frozenCode }

  @objc private func tick() { needsDisplay = true }

  package override func mouseDown(with event: NSEvent) { respond(kind: "mouseDown") }
  package override func keyDown(with event: NSEvent) {
    if !event.isARepeat { respond(kind: "keyDown") }
  }

  private func respond(kind: String) {
    responses += 1
    if events.count < 128 {
      events.append(WorkloadEvent(kind: kind, response: responses, elapsedSeconds: CACurrentMediaTime() - startedAt))
    }
    needsDisplay = true
  }

  package override func draw(_ dirtyRect: NSRect) {
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
