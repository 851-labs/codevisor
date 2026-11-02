import CoreVideo
import Foundation
import Synchronization

final class StillKeeper: Sendable {
  private struct Held: @unchecked Sendable {
    let version: Int
    let firstPtsNs: Int64
    let buffer: CVPixelBuffer
  }

  private static let settledWindowNs: Int64 = 2_000_000_000

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

  func offer(_ buffer: CVPixelBuffer, version: Int, ptsNs: Int64) {
    let finished = held.withLock { current -> Held? in
      if let same = current, same.version == version {
        if ptsNs - same.firstPtsNs <= Self.settledWindowNs {
          current = Held(version: version, firstPtsNs: same.firstPtsNs, buffer: buffer)
        }
        return nil
      }
      let previous = current
      current = versions.contains(version) ? Held(version: version, firstPtsNs: ptsNs, buffer: buffer) : nil
      return previous
    }
    if let finished { write(finished) }
  }

  func finish() async throws {
    if let last = held.withLock({ current in
      defer { current = nil }; return current
    }) {
      write(last)
    }
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
