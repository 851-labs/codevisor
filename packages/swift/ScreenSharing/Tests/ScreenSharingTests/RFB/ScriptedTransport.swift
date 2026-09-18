import Foundation
@testable import ScreenSharing

/// Serves scripted server bytes in the given chunks (so field boundaries
/// never line up with reads) and records everything the client writes.
final class ScriptedTransport: RFBTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var chunks: [[UInt8]]
  private(set) var written: [UInt8] = []
  private(set) var closed = false

  init(chunks: [[UInt8]]) { self.chunks = chunks }
  convenience init(_ bytes: [UInt8], chunk: Int = 3) {
    self.init(
      chunks: stride(from: 0, to: bytes.count, by: chunk).map { Array(bytes[$0..<min($0 + chunk, bytes.count)]) })
  }

  func read(maximum: Int) async throws -> [UInt8] {
    lock.withLock {
      guard !chunks.isEmpty else { return [] }
      let chunk = chunks[0]
      if chunk.count <= maximum {
        chunks.removeFirst()
        return chunk
      }
      chunks[0] = Array(chunk[maximum...])
      return Array(chunk[..<maximum])
    }
  }

  func write(_ bytes: [UInt8]) async throws { lock.withLock { written.append(contentsOf: bytes) } }
  func close() { lock.withLock { closed = true } }
}

extension Array where Element == UInt8 {
  init(hex: String) {
    let digits = Array<Character>(hex.filter { !$0.isWhitespace })
    self = stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
  }
}

func u32(_ value: UInt32) -> [UInt8] { var writer = RFBByteWriter(); writer.u32(value); return writer.bytes }
func u16(_ value: UInt16) -> [UInt8] { var writer = RFBByteWriter(); writer.u16(value); return writer.bytes }
