import Compression
import Foundation

/// Raw DEFLATE (RFC 1951, no zlib header) for negotiated-compression relay
/// channels — byte-compatible with node's deflateRaw/inflateRaw, which the
/// machine side uses. Apple's COMPRESSION_ZLIB is raw DEFLATE despite the
/// name.
enum CloudDeflate {
  /// Framing byte on negotiated channels: the body follows as-is.
  static let framingRaw: UInt8 = 0
  /// Framing byte on negotiated channels: the body is raw DEFLATE.
  static let framingDeflate: UInt8 = 1

  static func inflate(_ data: Data) throws -> Data {
    try process(data, operation: COMPRESSION_STREAM_DECODE)
  }

  static func deflate(_ data: Data) throws -> Data {
    try process(data, operation: COMPRESSION_STREAM_ENCODE)
  }

  private static func process(
    _ input: Data,
    operation: compression_stream_operation
  ) throws -> Data {
    guard !input.isEmpty else { return Data() }
    let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { streamPointer.deallocate() }
    guard
      compression_stream_init(streamPointer, operation, COMPRESSION_ZLIB)
        == COMPRESSION_STATUS_OK
    else { throw CloudDeflateError.streamFailed }
    defer { compression_stream_destroy(streamPointer) }

    let bufferSize = 64 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var output = Data()
    try input.withUnsafeBytes { (rawInput: UnsafeRawBufferPointer) in
      streamPointer.pointee.src_ptr = rawInput.bindMemory(to: UInt8.self).baseAddress!
      streamPointer.pointee.src_size = input.count
      while true {
        streamPointer.pointee.dst_ptr = buffer
        streamPointer.pointee.dst_size = bufferSize
        let status = compression_stream_process(
          streamPointer,
          Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
        )
        switch status {
        case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
          output.append(buffer, count: bufferSize - streamPointer.pointee.dst_size)
          if status == COMPRESSION_STATUS_END { return }
        // OK just means "more output pending" — loop for the next
        // buffer-full. Invalid input reports ERROR, never a livelock.
        case COMPRESSION_STATUS_ERROR:
          throw CloudDeflateError.corruptInput
        default:
          throw CloudDeflateError.streamFailed
        }
      }
    }
    return output
  }
}

enum CloudDeflateError: Error, Equatable, Sendable {
  case corruptInput
  case streamFailed
}
