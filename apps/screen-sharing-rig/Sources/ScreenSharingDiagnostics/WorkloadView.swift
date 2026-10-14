import AppKit
import ScreenSharing
import QuartzCore

@MainActor
package final class WorkloadWindow: NSWindow {
  package override var canBecomeKey: Bool { true }
  package override var canBecomeMain: Bool { true }
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
  private var drawRecord = ScreenSharingDrawTimestampRecord()
  package var drawSamples: [WorkloadDraw] {
    drawRecord.samples.map { WorkloadDraw(code: $0.code, startedAtSeconds: $0.startedAtSeconds) }
  }
  package var drawSamplesTruncated: Bool { drawRecord.truncated }
  public private(set) var firstDrawStartedAt: Double?
  public private(set) var firstDrawCompletedAt: Double?
  package var onFirstDraw: (() -> Void)?
  public private(set) var codes: ScreenSharingWorkloadSequence?
  package var isPaused: Bool { codes?.isFrozen ?? false }
  package override var acceptsFirstResponder: Bool { true }
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

  package func pause() {
    stop()
    codes?.freezeAtLastDrawn()
  }

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
