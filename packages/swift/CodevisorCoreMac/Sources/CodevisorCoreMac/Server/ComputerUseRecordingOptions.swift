import CoreGraphics
import Foundation

struct ComputerUseRecordingOptions {
  let windowID: CGWindowID?
  let displayID: CGDirectDisplayID?
  let fps: Int
  let maximumDimension: Int
  let maximumDuration: Int
  let showsCursor: Bool

  init(_ arguments: [String: Any]) throws {
    func integer(_ key: String, default fallback: Int? = nil, range: ClosedRange<Int>) throws -> Int? {
      guard let value = arguments[key] else { return fallback }
      guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
        range.contains(number.intValue)
      else { throw BridgeError("\(key) must be an integer in \(range).") }
      return number.intValue
    }
    windowID = try integer("window_id", range: 1...Int(UInt32.max)).map(CGWindowID.init)
    displayID = try integer("display_id", range: 1...Int(UInt32.max)).map(CGDirectDisplayID.init)
    guard (windowID == nil) != (displayID == nil) else {
      throw BridgeError("Choose exactly one window_id or display_id from list_recording_targets.")
    }
    fps = try integer("fps", default: 30, range: 1...60)!
    maximumDimension = try integer("max_dimension", default: 1920, range: 640...3840)!
    maximumDuration = try integer("max_duration_seconds", default: 60, range: 1...300)!
    if let cursor = arguments["show_cursor"], !(cursor is Bool) {
      throw BridgeError("show_cursor must be a boolean.")
    }
    showsCursor = arguments["show_cursor"] as? Bool ?? true
  }
}

func computerUseRecordingSize(_ size: CGSize, maximumDimension: Int) throws -> CGSize {
  guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
    throw BridgeError("The recording target has no usable dimensions.")
  }
  let scale = min(1, CGFloat(maximumDimension) / max(size.width, size.height))
  return CGSize(width: max(2, floor(size.width * scale / 2) * 2), height: max(2, floor(size.height * scale / 2) * 2))
}

func computerUseRecordingFileSize(_ url: URL) -> Int {
  // URL resource values can cache the size from before the writer flushed.
  (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
}

/// SDK callbacks complete on their own queues. Only bridge workers wait here.
final class ComputerUseRecordingResult<Value>: @unchecked Sendable {
  private let condition = NSCondition()
  private var result: Result<Value, Error>?

  func complete(_ value: Result<Value, Error>) {
    condition.lock()
    if result == nil { result = value }
    condition.broadcast()
    condition.unlock()
  }

  func wait(timeout: TimeInterval = 10) throws -> Value {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    while result == nil {
      guard condition.wait(until: deadline) else {
        throw BridgeError("Screen recording did not respond in time. Check recording_status before retrying.")
      }
    }
    return try result!.get()
  }
}
