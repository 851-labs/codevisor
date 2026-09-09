import Foundation

/// Opt-in native-app performance evidence. Production builds compile this to
/// no-ops. Records contain geometry and operation counts, never chat text.
public enum TranscriptPerformanceTrace {
  public static let isEnabled: Bool = {
    #if DEBUG
      ProcessInfo.processInfo.environment["TRANSCRIPT_STRESS"] == "1"
    #else
      false
    #endif
  }()

  public static func begin() -> UInt64 {
    isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
  }

  public static func record(_ name: String, since start: UInt64 = 0, values: @autoclosure () -> [String: Double] = [:])
  {
    guard isEnabled else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    let record = Record(
      name: name, time: Double(now) / 1e9,
      durationMS: start == 0 ? nil : Double(now - start) / 1e6, values: values())
    writer.queue.async { writer.append(record) }
  }

  private struct Record: Encodable, Sendable {
    let name: String
    let time: Double
    let durationMS: Double?
    let values: [String: Double]
  }

  private static let writer = Writer()
  private final class Writer: @unchecked Sendable {
    let queue = DispatchQueue(label: "codevisor.transcript-performance", qos: .utility)
    // All file access is confined to queue, outside native frame work.
    private var file: FileHandle?
    func append(_ record: Record) {
      if file == nil {
        let path = NSTemporaryDirectory() + "codevisor-transcript-performance.jsonl"
        FileManager.default.createFile(atPath: path, contents: nil)
        file = FileHandle(forWritingAtPath: path)
      }
      guard var data = try? JSONEncoder().encode(record) else { return }
      data.append(10)
      try? file?.write(contentsOf: data)
    }
  }
}
