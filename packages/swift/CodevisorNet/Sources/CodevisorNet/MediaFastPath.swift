import Foundation

#if canImport(codevisor_net_ffiFFI)
  import codevisor_net_ffiFFI
#endif

// The screen sharing media session's frame path (codevisor-media, 851-3815). Frames cross the Swift–Rust boundary
// through a small C ABI with borrowed buffers instead of uniffi's byte-by-byte `Data` marshalling.

/// `MediaSessionHandle.sendFrame` couldn't send a frame on this stream.
public struct MediaSendError: Error, Equatable {
  public let stream: UInt8
}

extension MediaSessionHandle {
  /// Host: sends one encoded tile, copied once into packets before this returns. Returns the frame's number within
  /// its stream. Throws when the connection doesn't carry datagrams or the frame or its metadata is too large.
  @discardableResult
  public func sendFrame(
    stream: UInt8, keyframe: Bool, ltrToken: UInt64?, meta: Data = Data(), data: UnsafeRawBufferPointer
  ) throws -> UInt32 {
    let number = meta.withUnsafeBytes { meta in
      codevisor_media_send_frame(
        uniffiCloneHandle(), stream, keyframe, ltrToken != nil, ltrToken ?? 0,
        meta.bindMemory(to: UInt8.self).baseAddress, meta.count, data.bindMemory(to: UInt8.self).baseAddress, data.count
      )
    }
    guard number >= 0 else { throw MediaSendError(stream: stream) }
    return UInt32(number)
  }

  /// Host: as above, from `Data`.
  @discardableResult
  public func sendFrame(
    stream: UInt8, keyframe: Bool, ltrToken: UInt64?, meta: Data = Data(), data: Data
  ) throws
    -> UInt32
  {
    try data.withUnsafeBytes {
      try sendFrame(stream: stream, keyframe: keyframe, ltrToken: ltrToken, meta: meta, data: $0)
    }
  }
}

extension MediaBytes {
  /// The frame's bytes, read in place; valid only inside `body`.
  public func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
    try withExtendedLifetime(self) {
      var count = 0
      let start = codevisor_media_bytes(uniffiCloneHandle(), &count)
      return try body(UnsafeRawBufferPointer(start: start, count: count))
    }
  }

  /// A copy of the frame's bytes.
  public var data: Data {
    withUnsafeBytes { Data($0) }
  }
}
