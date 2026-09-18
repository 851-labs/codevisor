import AppKit
import ScreenSharing
import CoreMedia
import QuartzCore
@preconcurrency import ScreenCaptureKit

/// Samples only the benchmark marker from a user-selected window. No frames,
/// audio or input are retained. An external analysis combines these local host
/// timestamps with the workload's clock and measured clock-offset bounds.
@MainActor
enum ProbeWindowObservation {
  struct Options {
    let sourceWidth: Int
    let sourceHeight: Int
    let contentTopPoints: Double
    let duration: Double
    let report: URL
    let windowID: UInt32?
    let captureKind: String

    init(arguments: [String]) throws {
      let allowed = Set([
        "--width", "--height", "--content-top-points", "--duration", "--report", "--window-id", "--capture-kind",
      ])
      guard arguments.count.isMultiple(of: 2) else {
        throw ScreenSharingError.invalid("Observation options require values.")
      }
      var values: [String: String] = [:]
      for index in stride(from: 0, to: arguments.count, by: 2) {
        let key = arguments[index]
        guard allowed.contains(key), values[key] == nil else {
          throw ScreenSharingError.invalid("Unsupported or repeated observation option: \(key)")
        }
        values[key] = arguments[index + 1]
      }
      // Below 900 source pixels the workload response panel overlaps the marker.
      guard let width = Int(values["--width"] ?? "3840"), (900...3840).contains(width),
        let height = Int(values["--height"] ?? "2160"), (360...2160).contains(height),
        let top = Double(values["--content-top-points"] ?? "0"), top.isFinite, (0...300).contains(top),
        let duration = Double(values["--duration"] ?? "30"), duration.isFinite, (1...120).contains(duration),
        let path = values["--report"], !path.isEmpty
      else { throw ScreenSharingError.invalid("Invalid observation geometry, duration or report path.") }
      sourceWidth = width; sourceHeight = height; contentTopPoints = top
      self.duration = duration
      report = URL(fileURLWithPath: path).standardizedFileURL
      if let value = values["--window-id"] {
        guard let id = UInt32(value), id > 0 else { throw ScreenSharingError.invalid("Invalid window ID.") }
        windowID = id
      } else {
        windowID = nil
      }
      captureKind = values["--capture-kind"] ?? "window"
      guard ["window", "display-crop"].contains(captureKind), captureKind != "display-crop" || windowID != nil else {
        throw ScreenSharingError.invalid("Choose window or display-crop capture; display-crop requires a window ID.")
      }
    }
  }

  static func run(options: Options) async throws {
    let picker = ProbeCapturePicker()
    defer { picker.stop() }
    let filter: SCContentFilter
    var sourceRect: CGRect?
    var displayID: UInt32?
    if let windowID = options.windowID {
      guard CGPreflightScreenCaptureAccess() else {
        throw ScreenSharingError.unavailable("Direct window observation requires existing Screen Recording permission.")
      }
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
      guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
        throw ScreenSharingError.unavailable("The requested window is no longer available.")
      }
      if options.captureKind == "display-crop" {
        guard window.isOnScreen,
          let display = content.displays.first(where: { $0.frame.contains(window.frame) })
        else {
          throw ScreenSharingError.unavailable(
            "Display observation requires the entire window on one attached display. "
              + "Window \(windowID): onScreen=\(window.isOnScreen), frame=\(window.frame); "
              + "displays=\(content.displays.map { "\($0.displayID):\($0.frame)" })")
        }
        filter = SCContentFilter(display: display, excludingWindows: [])
        sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        displayID = display.displayID
      } else {
        filter = SCContentFilter(desktopIndependentWindow: window)
      }
    } else {
      filter = try await picker.choose(window: true)
    }
    let bounds = sourceRect ?? filter.contentRect
    let contentHeight = bounds.height - options.contentTopPoints
    guard bounds.width >= 300, contentHeight >= 180,
      abs(bounds.width / contentHeight - Double(options.sourceWidth) / Double(options.sourceHeight)) < 0.02
    else { throw ScreenSharingError.invalid("Selected window/content inset does not match the source aspect ratio.") }
    let scale = min(Double(filter.pointPixelScale), 1920 / bounds.width)
    let width = Int((bounds.width * scale).rounded())
    let height = Int((bounds.height * scale).rounded())
    let config = SCStreamConfiguration()
    config.width = width; config.height = height
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    config.queueDepth = 3
    config.showsCursor = false
    config.capturesAudio = false
    config.ignoreShadowsSingleWindow = true
    config.scalesToFit = true
    if let sourceRect { config.sourceRect = sourceRect }
    let output = ObservationOutput(
      sourceWidth: options.sourceWidth, sourceHeight: options.sourceHeight,
      topFraction: options.contentTopPoints / bounds.height)
    let stream = SCStream(filter: filter, configuration: config, delegate: output)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
    let started = CACurrentMediaTime()
    let clockDifference = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CACurrentMediaTime()
    try await stream.startCapture()
    var ready: [String: Any] = [
      "captureKind": options.captureKind,
      "widthPoints": bounds.width, "heightPoints": bounds.height,
      "contentTopPoints": options.contentTopPoints, "captureWidth": width, "captureHeight": height,
      "startedAtSeconds": started, "hostClockMinusCoreAnimationSeconds": clockDifference,
    ]
    if let displayID { ready["displayID"] = displayID }
    if let sourceRect {
      ready["sourceRectPoints"] = [sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height]
    }
    do {
      try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: options.report.path + ".ready.json"), options: .atomic)
      try await Task.sleep(for: .seconds(options.duration))
      try await stream.stopCapture()
    } catch {
      try? await stream.stopCapture()
      throw error
    }
    let snapshot = await output.finish()
    let report = Report(
      captureKind: options.captureKind, displayID: displayID,
      sourceRectPoints: sourceRect.map { [$0.minX, $0.minY, $0.width, $0.height] },
      sourceWidth: options.sourceWidth, sourceHeight: options.sourceHeight,
      contentTopPoints: options.contentTopPoints, captureWidth: width, captureHeight: height,
      elapsedSeconds: CACurrentMediaTime() - started,
      hostClockMinusCoreAnimationSeconds: clockDifference, observation: snapshot)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: options.report, options: .atomic)
    guard snapshot.failure == nil, !snapshot.truncated, !snapshot.samples.isEmpty,
      snapshot.samples.contains(where: { $0.code != nil })
    else { throw ScreenSharingError.unavailable("Observation did not produce valid bounded marker samples.") }
    print(
      "Observed \(snapshot.samples.count) \(options.captureKind) samples; image-age analysis requires clock calibration."
    )
  }

  private struct Report: Encodable {
    let kind = "window-marker-observation"
    let timingScope = "Local ScreenCaptureKit sample timestamps; not physical presentation or input-to-photon"
    let captureKind: String
    let displayID: UInt32?
    let sourceRectPoints: [Double]?
    let sourceWidth: Int
    let sourceHeight: Int
    let contentTopPoints: Double
    let captureWidth: Int
    let captureHeight: Int
    let elapsedSeconds: Double
    let hostClockMinusCoreAnimationSeconds: Double
    let observation: ObservationOutput.Snapshot
  }
}

private final class ObservationOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let queue = DispatchQueue(label: "codevisor.probe.window-observation", qos: .userInteractive)
  private let sourceWidth: Int
  private let sourceHeight: Int
  private let topFraction: Double
  private let lock = NSLock()
  private var samples: [Sample] = []
  private var incompleteSamples = 0
  private var truncated = false
  private var failure: String?

  struct Sample: Encodable, Sendable {
    let samplePTSSeconds: Double
    let callbackSeconds: Double
    let code: Int?
    let width: Int
    let height: Int
  }

  struct Snapshot: Encodable, Sendable {
    let samples: [Sample]
    let incompleteSamples: Int
    let truncated: Bool
    let failure: String?
  }

  init(sourceWidth: Int, sourceHeight: Int, topFraction: Double) {
    self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight; self.topFraction = topFraction
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen else { return }
    let callback = CACurrentMediaTime()
    guard buffer.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
      let pixel = buffer.imageBuffer, buffer.presentationTimeStamp.isNumeric
    else { lock.withLock { incompleteSamples += 1 }; return }
    let sample = Sample(
      samplePTSSeconds: CMTimeGetSeconds(buffer.presentationTimeStamp), callbackSeconds: callback,
      code: decode(pixel), width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
    lock.withLock {
      guard samples.count < 20_000 else { truncated = true; return }
      samples.append(sample)
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    lock.withLock { failure = error.localizedDescription }
  }

  func finish() async -> Snapshot {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(
          returning: self.lock.withLock {
            Snapshot(
              samples: self.samples, incompleteSamples: self.incompleteSamples,
              truncated: self.truncated, failure: self.failure)
          })
      }
    }
  }

  private func decode(_ pixel: CVPixelBuffer) -> Int? {
    guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
      CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess
    else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard let raw = CVPixelBufferGetBaseAddress(pixel) else { return nil }
    let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
    let stride = CVPixelBufferGetBytesPerRow(pixel)
    let bytes = raw.assumingMemoryBound(to: UInt8.self)
    let top = Double(height) * topFraction
    let cy = Int((top + 105 * (Double(height) - top) / Double(sourceHeight)).rounded())
    guard cy >= 1, cy + 1 < height else { return nil }
    var cells: [Double] = []
    for index in 0..<20 {
      let cx = Int((Double(36 + 28 * index) * Double(width) / Double(sourceWidth)).rounded())
      guard cx >= 1, cx + 1 < width else { return nil }
      var values: [Double] = []
      for y in (cy - 1)...(cy + 1) {
        for x in (cx - 1)...(cx + 1) {
          let offset = y * stride + x * 4
          values.append((Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])) / 3)
        }
      }
      cells.append(values.sorted()[4])
    }
    guard let white = cells.first, let black = cells.last, white - black >= 120 else { return nil }
    var code = 0
    for cell in cells.dropFirst().dropLast() {
      let normalized = (cell - black) / (white - black)
      guard normalized <= 0.2 || normalized >= 0.8 else { return nil }
      code = (code << 1) | (normalized >= 0.5 ? 1 : 0)
    }
    return code
  }
}
