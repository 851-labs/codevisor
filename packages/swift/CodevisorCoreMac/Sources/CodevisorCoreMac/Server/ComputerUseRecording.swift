import AVFoundation
import Foundation
import ScreenCaptureKit

/// A recording owns its native stream until the file-finalized callback arrives.
final class ComputerUseRecording: NSObject, SCStreamDelegate, @unchecked Sendable {
  let id = UUID().uuidString
  let sessionID: String
  let target: [String: Any]
  let options: ComputerUseRecordingOptions
  let size: CGSize
  let fileURL: URL
  private let condition = NSCondition()
  private let operationLock = NSLock()
  private var state = "starting"
  private var failure: String?
  private var stopReason: String?
  private var startedAt: TimeInterval?
  private var timer: DispatchSourceTimer?
  private var stream: SCStream!
  private var output: ComputerUseVideoWriter?
  private var finalDuration: Double?
  var onFinish: (@Sendable () -> Void)?

  init(sessionID: String, target: [String: Any], options: ComputerUseRecordingOptions, size: CGSize, directory: URL) {
    self.sessionID = sessionID
    self.target = target
    self.options = options
    self.size = size
    fileURL = directory.appendingPathComponent("recording-\(id).mp4")
    super.init()
  }

  func start(filter: SCContentFilter) throws {
    operationLock.lock()
    defer { operationLock.unlock() }
    guard !isFinished else { throw BridgeError("The recording was cancelled before capture started.") }
    let config = SCStreamConfiguration()
    config.width = Int(size.width)
    config.height = Int(size.height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(options.fps))
    config.showsCursor = options.showsCursor
    config.capturesAudio = false
    config.scalesToFit = true
    config.queueDepth = 3
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.ignoreShadowsSingleWindow = true
    stream = SCStream(filter: filter, configuration: config, delegate: self)
    let video = try ComputerUseVideoWriter(
      url: fileURL, size: size, fps: options.fps,
      onStarted: { [weak self] in self?.captureStarted() },
      onFinished: { [weak self] duration in self?.captureFinished(duration: duration) },
      onError: { [weak self] error in self?.fail(error) })
    output = video
    try stream.addStreamOutput(video, type: .screen, sampleHandlerQueue: video.queue)
    let result = ComputerUseRecordingResult<Void>()
    stream.startCapture { error in
      result.complete(error.map { .failure($0) } ?? .success(()))
    }
    try result.wait()
    try waitForState { $0 != "starting" }
    let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    monitor.schedule(deadline: .now() + 1, repeating: 1)
    monitor.setEventHandler { [weak self] in self?.checkLimits() }
    condition.lock()
    timer = monitor
    if state != "recording" { monitor.cancel() }
    condition.unlock()
    monitor.resume()
  }

  func stop(reason: String = "requested") throws {
    operationLock.lock()
    defer { operationLock.unlock() }
    condition.lock()
    if stream == nil && state == "starting" {
      state = "cancelled"
      stopReason = reason
      condition.broadcast()
      condition.unlock()
      onFinish?()
      return
    }
    let shouldStop = state == "recording" || state == "starting"
    let duration = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
    if shouldStop {
      state = "stopping"
      stopReason = reason
    }
    condition.unlock()
    if shouldStop {
      let result = ComputerUseRecordingResult<Void>()
      stream.stopCapture { error in result.complete(error.map { .failure($0) } ?? .success(())) }
      // The output delegate is authoritative about whether the MP4 finalized.
      do { try result.wait() } catch {
        if !isFinished { fail(error); throw error }
      }
      output?.finish(duration: duration)
    }
    try waitForState { $0 == "stopped" || $0 == "failed" || $0 == "cancelled" }
  }

  var isFinished: Bool {
    condition.lock()
    defer { condition.unlock() }
    return state == "stopped" || state == "failed" || state == "cancelled"
  }

  func metadata() -> [String: Any] {
    condition.lock()
    defer { condition.unlock() }
    let duration = finalDuration ?? startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
    var result: [String: Any] = [
      "recordingId": id, "status": state, "target": target,
      "durationSeconds": duration.isFinite ? duration : 0,
      "width": Int(size.width), "height": Int(size.height), "fps": options.fps,
      "maxDurationSeconds": options.maximumDuration, "audio": false,
    ]
    if let stopReason { result["stopReason"] = stopReason }
    if let failure { result["error"] = failure }
    if state == "stopped" {
      let bytes = computerUseRecordingFileSize(fileURL)
      result["file"] = [
        "path": fileURL.path, "name": fileURL.lastPathComponent, "mimeType": "video/mp4", "sizeBytes": bytes,
      ]
    }
    return result
  }

  private func waitForState(_ predicate: (String) -> Bool) throws {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(10)
    while !predicate(state) {
      guard condition.wait(until: deadline) else {
        throw BridgeError(
          "Recording \(id) is still \(state). Check recording_status; do not start a duplicate recording.")
      }
    }
    if let failure { throw BridgeError("Recording \(id) failed: \(failure)") }
  }

  private func checkLimits() {
    condition.lock()
    let elapsed = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
    let reason =
      elapsed >= Double(options.maximumDuration)
      ? "duration_limit"
      : computerUseRecordingFileSize(fileURL) >= 100 * 1024 * 1024 ? "size_limit" : nil
    let active = state == "recording"
    condition.unlock()
    if active, let reason { try? stop(reason: reason) }
  }

  func fail(_ error: Error) {
    condition.lock()
    guard state != "failed" && state != "stopped" else { condition.unlock(); return }
    failure = error.localizedDescription
    state = "failed"
    timer?.cancel()
    condition.broadcast()
    condition.unlock()
    stream?.stopCapture { _ in }
    output?.cancel()
    onFinish?()
  }

  func captureStarted() {
    condition.lock()
    if state == "starting" { state = "recording" }
    startedAt = ProcessInfo.processInfo.systemUptime
    condition.broadcast()
    condition.unlock()
  }

  func captureFinished(duration: Double) {
    condition.lock()
    if failure == nil { state = "stopped" }
    finalDuration = duration
    timer?.cancel()
    condition.broadcast()
    condition.unlock()
    onFinish?()
  }

  private func elapsedDuration() -> Double {
    condition.lock()
    defer { condition.unlock() }
    return startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    let native = error as NSError
    if native.domain == SCStreamErrorDomain && native.code == SCStreamError.userStopped.rawValue {
      condition.lock()
      if state == "recording" { state = "stopping"; stopReason = "user_stopped" }
      condition.unlock()
      output?.finish(duration: elapsedDuration())
    } else {
      fail(error)
    }
  }
}
