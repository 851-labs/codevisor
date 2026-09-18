import ScreenSharing
import Foundation

public final class RigTelemetryWriter: @unchecked Sendable {
  public let url: URL
  public let maximumBytes: Int
  private let lock = NSLock()
  private var handle: FileHandle?
  private var size = 0

  public init(directory: URL, role: String, maximumBytes: Int = 50_000_000) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    url = directory.appendingPathComponent("\(role).jsonl")
    self.maximumBytes = maximumBytes
    try open()
  }

  private func open() throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    size = Int(try handle.seekToEnd())
    self.handle = handle
  }

  public func append(_ sample: RigTelemetrySample) throws {
    let line = try RigJSON.encode(sample) + Data([10])
    try lock.withLock {
      if size + line.count > maximumBytes {
        try handle?.close()
        handle = nil
        let rotated = url.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? FileManager.default.removeItem(at: rotated)
        try FileManager.default.moveItem(at: url, to: rotated)
        try open()
      }
      try handle?.write(contentsOf: line)
      size += line.count
    }
  }

  public func close() {
    lock.withLock {
      try? handle?.close()
      handle = nil
    }
  }
}
