import AppKit
import ScreenSharing
import ScreenSharingDiagnostics
import QuartzCore

/// A common desktop target for external viewers. Counters describe AppKit draw
/// calls and received events, never claimed source/display presentation times.
@MainActor
enum ProbeDesktopWorkload {
  static func run(options: ProbeOptions) async throws {
    guard let screen = NSScreen.main else { throw ScreenSharingError.unavailable("No desktop display.") }
    let painter = try ProbeDesktopPainter.make(
      width: options.configuration.width, height: options.configuration.height,
      fps: options.configuration.framesPerSecond)
    let view = WorkloadView(painter: painter, recordDrawTimes: options.recordWorkloadTimes)
    let contentFrame: NSRect
    if options.workloadWindow {
      let size = NSSize(
        width: Double(options.configuration.width) / screen.backingScaleFactor,
        height: Double(options.configuration.height) / screen.backingScaleFactor)
      contentFrame = NSRect(
        x: screen.frame.minX, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    } else {
      contentFrame = screen.frame
    }
    let window = WorkloadWindow(
      contentRect: contentFrame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    window.title = "Codevisor · Screen Sharing Benchmark Workload"
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.contentView = view
    let previousPresentation = NSApplication.shared.presentationOptions
    NSApplication.shared.presentationOptions = [.autoHideDock, .autoHideMenuBar]
    defer {
      view.stop()
      window.orderOut(nil)
      NSApplication.shared.presentationOptions = previousPresentation
    }
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    NSApplication.shared.activate()
    view.start()
    if let report = options.reportURL {
      let ready: [String: Any] = [
        "windowID": window.windowNumber,
        "widthPoints": view.bounds.width, "heightPoints": view.bounds.height,
        "backingScaleFactor": window.backingScaleFactor,
        "rasterWidth": options.configuration.width, "rasterHeight": options.configuration.height,
        "startedAtSeconds": view.startedAt,
        "layout": options.workloadWindow ? "exact backing size" : "fullscreen",
      ]
      try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: report.path + ".ready.json"), options: .atomic)
    }
    print("Desktop workload ready: click or press Space for a response; no capture or input injection.")
    try await Task.sleep(for: .seconds(options.duration))
    view.stop()
    let report = WorkloadReport(
      rasterWidth: options.configuration.width, rasterHeight: options.configuration.height,
      windowWidthPoints: view.bounds.width, windowHeightPoints: view.bounds.height,
      backingScaleFactor: window.backingScaleFactor, requestedFPS: options.configuration.framesPerSecond,
      startedAtSeconds: view.startedAt,
      elapsedSeconds: CACurrentMediaTime() - view.startedAt, drawCalls: view.drawCalls,
      lastSequence: view.sequence, responses: view.responses, eventSamples: view.events,
      eventSamplesTruncated: view.responses > view.events.count,
      drawSamples: view.drawSamples, drawSamplesTruncated: view.drawSamplesTruncated)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    if let url = options.reportURL { try data.write(to: url, options: .atomic) }
    print(String(decoding: data, as: UTF8.self))
  }
}

private struct WorkloadReport: Encodable {
  let kind = "desktop-workload"
  let timingScope = "AppKit draw calls and event receipt; not physical presentation or input-to-photon"
  let rasterWidth: Int
  let rasterHeight: Int
  let windowWidthPoints: Double
  let windowHeightPoints: Double
  let backingScaleFactor: Double
  let requestedFPS: Int
  let startedAtSeconds: Double
  let elapsedSeconds: Double
  let drawCalls: Int
  let lastSequence: Int
  let responses: Int
  let eventSamples: [WorkloadEvent]
  let eventSamplesTruncated: Bool
  let drawSamples: [WorkloadDraw]
  let drawSamplesTruncated: Bool
}
