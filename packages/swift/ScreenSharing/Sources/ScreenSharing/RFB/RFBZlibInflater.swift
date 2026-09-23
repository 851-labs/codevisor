import CZlib
import Foundation

/// One zlib stream that persists for the connection, as ZRLE requires: each
/// rectangle's compressed bytes continue the same stream.
final class RFBZlibInflater {
  private var stream = z_stream()
  private var open = false

  init() throws {
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw RFBError.malformed("zlib initialisation failed")
    }
    open = true
  }

  deinit { if open { inflateEnd(&stream) } }

  /// Consumes all of `input` and returns everything it produced.
  func inflate(_ input: [UInt8]) throws -> [UInt8] {
    var output: [UInt8] = []
    var scratch = [UInt8](repeating: 0, count: 1 << 16)
    var input = input
    try input.withUnsafeMutableBufferPointer { source in
      stream.next_in = source.baseAddress
      stream.avail_in = UInt32(source.count)
      repeat {
        let status = scratch.withUnsafeMutableBufferPointer { destination -> Int32 in
          stream.next_out = destination.baseAddress
          stream.avail_out = UInt32(destination.count)
          return CZlib.inflate(&stream, Z_SYNC_FLUSH)
        }
        let produced = scratch.count - Int(stream.avail_out)
        output.append(contentsOf: scratch[0..<produced])
        switch status {
        case Z_OK, Z_STREAM_END: break
        case Z_BUF_ERROR where produced == 0: return
        default: throw RFBError.malformed("zlib error \(status)")
        }
        if status == Z_STREAM_END { return }
      } while stream.avail_in > 0 || stream.avail_out == 0
    }
    return output
  }
}

/// The server side, for the loopback server: sync-flushed so each rectangle
/// is decodable on arrival while the stream stays open.
package final class RFBZlibDeflater {
  private var stream = z_stream()
  private var open = false

  /// `level`: zlib 0…9; the default suits ZRLE, Tight uses 1 as TigerVNC does for its default compression level.
  package init(level: Int32 = Z_DEFAULT_COMPRESSION) throws {
    guard deflateInit_(&stream, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { throw RFBError.malformed("zlib initialisation failed") }
    open = true
  }

  deinit { if open { deflateEnd(&stream) } }

  package func deflate(_ input: [UInt8]) throws -> [UInt8] {
    var output: [UInt8] = []
    var scratch = [UInt8](repeating: 0, count: 1 << 16)
    var input = input
    try input.withUnsafeMutableBufferPointer { source in
      stream.next_in = source.baseAddress
      stream.avail_in = UInt32(source.count)
      repeat {
        let status = scratch.withUnsafeMutableBufferPointer { destination -> Int32 in
          stream.next_out = destination.baseAddress
          stream.avail_out = UInt32(destination.count)
          return CZlib.deflate(&stream, Z_SYNC_FLUSH)
        }
        guard status == Z_OK || status == Z_BUF_ERROR else { throw RFBError.malformed("zlib error \(status)") }
        output.append(contentsOf: scratch[0..<(scratch.count - Int(stream.avail_out))])
      } while stream.avail_out == 0
    }
    return output
  }
}
