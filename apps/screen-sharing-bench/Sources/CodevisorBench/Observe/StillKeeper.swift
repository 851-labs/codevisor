import CoreVideo
import Foundation
import Synchronization

final class StillKeeper: Sendable {
  private struct Held: @unchecked Sendable {
    let version: Int
    let buffer: CVPixelBuffer
  }

  private let directory: URL
  private let versions: Set<Int>
  private let writer = DispatchQueue(label: "CodevisorBench observer stills", qos: .utility)
  private let held = Mutex<Held?>(nil)
  private let failure = Mutex<(any Error)?>(nil)

  init(_ options: StillsOptions) throws {
    directory = URL(fileURLWithPath: options.directory)
    versions = options.versions
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func offer(_ buffer: CVPixelBuffer, version: Int) {
    let next = versions.contains(version) ? Held(version: version, buffer: buffer) : nil
    let finished = held.withLock { current -> Held? in
      let previous = current
      current = next
      return previous?.version == version ? nil : previous
    }
    if let finished { write(finished) }
  }

  func finish() async throws {
    if let last = held.withLock({ current in defer { current = nil }; return current }) { write(last) }
    await withCheckedContinuation { continuation in writer.async { continuation.resume() } }
    if let error = failure.withLock({ $0 }) { throw error }
  }

  private func write(_ still: Held) {
    let url = directory.appending(path: "\(still.version).png")
    writer.async { self.save(still, to: url) }
  }

  private func save(_ still: Held, to url: URL) {
    do {
      try StillImage.write(still.buffer, to: url)
    } catch {
      failure.withLock { $0 = $0 ?? error }
    }
  }
}
