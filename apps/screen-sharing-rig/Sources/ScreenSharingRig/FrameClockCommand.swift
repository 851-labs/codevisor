#if os(macOS)
  import AppKit
  import CoreMedia
  import Foundation
  @preconcurrency import ScreenCaptureKit
  import ScreenSharingRigKit

  /// `screen-sharing-rig frame-clock`: the viewer side of the cross-app frame
  /// clock (851-2358). Captures one window of each named app, and nothing else,
  /// at up to 60 frames per second, reads the host page's strip in every frame
  /// and reports what each viewer showed and how far each trails the others.
  /// All windows share one capture clock (host time), so lags compare directly.
  enum FrameClockCommand {
    static let usage = """
      Usage: screen-sharing-rig frame-clock --app BUNDLE_ID [--app BUNDLE_ID …] [--seconds 20]
                                            [--out DIR]
      Captures the largest on-screen window of each app (e.g. com.codevisor.ScreenSharingRig,
      com.apple.ScreenSharing): only those windows, never the display. Start the host page
      (apps/screen-sharing-rig/frame-clock/index.html) first, or reload it while this runs,
      so each window shows the orange calibration strip to calibrate on. Prints one JSON object:
      per app, updates/s, share of host frames shown, gap p50/p95/max, torn and unreadable
      fractions; and each app's lag behind every other (p50/p95 ms). With --out, writes each
      app's samples as JSON lines too.
      """

    static func main(arguments: [String]) {
      if arguments.contains("--help") {
        print(usage)
        return
      }
      var apps: [String] = [], seconds = 20.0, out: URL?
      var iterator = arguments.makeIterator()
      while let argument = iterator.next() {
        guard let value = iterator.next() else { fail("\(argument) needs a value\n\n\(usage)") }
        switch argument {
        case "--app": apps.append(value)
        case "--seconds": seconds = Double(value) ?? seconds
        case "--out": out = URL(fileURLWithPath: value)
        default: fail("unknown option \(argument)\n\n\(usage)")
        }
      }
      guard !apps.isEmpty, seconds > 0 else { fail(usage) }
      // ScreenCaptureKit needs the process's window-server connection, which AppKit sets up.
      NSApplication.shared.setActivationPolicy(.prohibited)
      Task {
        do {
          let result = try await run(apps: apps, seconds: seconds, out: out)
          let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
          print(String(decoding: data, as: UTF8.self))
          exit(EXIT_SUCCESS)
        } catch {
          fail("frame-clock: \(error.localizedDescription)")
        }
      }
      dispatchMain()
    }

    static func run(apps: [String], seconds: Double, out: URL?) async throws -> [String: Any] {
      let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
      var streams: [(app: String, stream: SCStream, reader: FrameClockReader, size: CGSize)] = []
      for app in apps {
        guard
          let window = content.windows.filter({
            $0.owningApplication?.bundleIdentifier == app && $0.windowLayer == 0 && $0.frame.width >= 200
          }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { throw Failure("no on-screen window of \(app)") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // One pixel per point: the strip's cells are tens of points wide, and two 60 fps captures stay cheap.
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 4
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        let reader = FrameClockReader(app: app)
        let stream = SCStream(filter: filter, configuration: config, delegate: reader)
        try stream.addStreamOutput(reader, type: .screen, sampleHandlerQueue: reader.queue)
        streams.append((app, stream, reader, window.frame.size))
      }
      for entry in streams { try await entry.stream.startCapture() }
      // Measure `seconds` from when every window has read its first frame (after calibrating on
      // the orange calibration strip: reload or click the host page any time after starting). Five minutes at most.
      let deadline = ContinuousClock.now.advanced(by: .seconds(300))
      while ContinuousClock.now < deadline, !streams.allSatisfy({ $0.reader.isCounting }) {
        try await Task.sleep(for: .milliseconds(250))
      }
      guard streams.allSatisfy({ $0.reader.isCounting }) else {
        for entry in streams { try? await entry.stream.stopCapture() }
        let waiting = streams.filter { !$0.reader.isCounting }.map(\.app).joined(separator: ", ")
        throw Failure(
          "no frame read within 5 minutes from \(waiting): show the orange calibration strip (reload or click the page)"
        )
      }
      FileHandle.standardError.write(Data("frame-clock: every window calibrated; measuring \(seconds) s\n".utf8))
      for entry in streams { entry.reader.reset() }
      try await Task.sleep(for: .seconds(seconds))
      for entry in streams { try? await entry.stream.stopCapture() }

      var timelines: [String: FrameClockTimeline] = [:]
      var result: [String: Any] = ["seconds": seconds]
      var perApp: [String: Any] = [:]
      for entry in streams {
        let snapshot = await entry.reader.finish()
        let timeline = FrameClockTimeline(samples: snapshot.samples)
        timelines[entry.app] = timeline
        var summary: [String: Any] = [
          "window": "\(Int(entry.size.width))x\(Int(entry.size.height))", "captures": snapshot.samples.count,
          "calibrated": snapshot.strip != nil,
        ]
        if let failure = snapshot.failure { summary["failure"] = failure }
        if let s = timeline.summary {
          func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }
          summary["updatesPerSecond"] = round(s.updatesPerSecond)
          summary["hostFramesShown"] = round(s.hostFramesShown)
          summary["gapP50Ms"] = round(s.gapP50Milliseconds)
          summary["gapP95Ms"] = round(s.gapP95Milliseconds)
          summary["gapMaxMs"] = round(s.gapMaximumMilliseconds)
          summary["tornFraction"] = round(s.tornFraction)
          summary["unreadableFraction"] = round(s.unreadableFraction)
        }
        perApp[entry.app] = summary
        if let out {
          try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
          let lines = snapshot.samples.map { sample -> String in
            switch sample.reading {
            case .frame(let frame): "{\"t\":\(sample.time),\"frame\":\(frame)}"
            case .torn: "{\"t\":\(sample.time),\"torn\":true}"
            case .unreadable: "{\"t\":\(sample.time),\"unreadable\":true}"
            }
          }
          try (lines.joined(separator: "\n") + "\n").write(
            to: out.appendingPathComponent("\(entry.app).jsonl"), atomically: true, encoding: .utf8)
        }
      }
      result["apps"] = perApp
      var lags: [String: Any] = [:]
      for (app, timeline) in timelines {
        for (other, reference) in timelines where other != app {
          if let lag = timeline.lag(behind: reference) {
            lags["\(app) behind \(other)"] = ["p50Ms": lag.p50.rounded(), "p95Ms": lag.p95.rounded()]
          }
        }
      }
      result["lags"] = lags
      return result
    }

    struct Failure: LocalizedError {
      let errorDescription: String?
      init(_ message: String) { errorDescription = message }
    }

    private static func fail(_ message: String) -> Never {
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      exit(2)
    }
  }

  /// One window's stream: finds the strip while it's orange, then reads every complete frame.
  final class FrameClockReader: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Snapshot {
      var samples: [FrameClockTimeline.Sample]
      var strip: (x: Int, y: Int, width: Int, height: Int)?
      var failure: String?
    }

    let app: String
    let queue: DispatchQueue
    private let lock = NSLock()
    private var samples: [FrameClockTimeline.Sample] = []
    private var strip: (x: Int, y: Int, width: Int, height: Int)?
    private var counting = false
    private var failure: String?

    init(app: String) {
      self.app = app
      queue = DispatchQueue(label: "frame-clock.\(app)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
      guard type == .screen, buffer.isValid,
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
          as? [[SCStreamFrameInfo: Any]],
        let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
        let pixel = buffer.imageBuffer, buffer.presentationTimeStamp.isNumeric,
        CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
        CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess
      else { return }
      defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
      guard let base = CVPixelBufferGetBaseAddress(pixel) else { return }
      let image = FrameClockImage(
        width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel),
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
        pixels: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)))
      let time = CMTimeGetSeconds(buffer.presentationTimeStamp)
      // Calibrate on the orange calibration strip (again, if the page is reloaded); read otherwise.
      if let found = image.locateStrip() {
        lock.withLock { strip = found }
        return
      }
      guard let strip = lock.withLock({ strip }) else { return }
      let reading = FrameClock.read(image.cellAverages(in: strip))
      lock.withLock {
        // Samples count from the first frame read: calibration isn't part of the measurement.
        if case .frame = reading { counting = true }
        if counting, samples.count < 100_000 { samples.append(.init(time: time, reading: reading)) }
      }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
      lock.withLock { failure = error.localizedDescription }
    }

    /// A frame has been read since calibrating.
    var isCounting: Bool { lock.withLock { counting } }

    /// Starts the measurement over (keeping the calibration).
    func reset() { lock.withLock { samples = [] } }

    func finish() async -> Snapshot {
      await withCheckedContinuation { continuation in
        queue.async {
          continuation.resume(
            returning: self.lock.withLock { Snapshot(samples: self.samples, strip: self.strip, failure: self.failure) })
        }
      }
    }
  }
#endif
