import Foundation

#if canImport(codevisor_net_ffiFFI)
  import codevisor_net_ffiFFI
#endif

// The screen sharing media session's frame path (codevisor-media, 851-3815). Frames cross the Swift–Rust boundary
// through a small C ABI with borrowed buffers instead of uniffi's byte-by-byte `Data` marshalling.

/// Why `MediaSessionHandle.sendFrame` didn't send a frame.
public enum MediaSendError: Error, Equatable {
  /// The connection doesn't carry datagrams.
  case noDatagrams
  /// The path's datagrams can't hold a media header.
  case pathTooSmall
  /// The metadata is over 64 KiB.
  case metaTooLarge
  /// The frame needs more than 65 535 packets.
  case frameTooLarge
  case internalFailure

  init(code: Int64) {
    switch code {
    case -1: self = .noDatagrams
    case -2: self = .pathTooSmall
    case -3: self = .metaTooLarge
    case -4: self = .frameTooLarge
    default: self = .internalFailure
    }
  }
}

extension MediaSessionHandle {
  /// Host: sends one encoded tile, copied before this returns (so `data` is free again at once). Returns the frame's
  /// number within its stream.
  @discardableResult
  public func sendFrame(
    stream: UInt8, keyframe: Bool, ltrToken: UInt64?, meta: Data = Data(), data: UnsafeRawBufferPointer
  ) throws -> UInt32 {
    let number = meta.withUnsafeBytes { meta in
      codevisor_media_send_frame(
        uniffiCloneHandle(), stream, keyframe, ltrToken != nil, ltrToken ?? 0,
        meta.baseAddress, meta.count, data.baseAddress, data.count)
    }
    guard number >= 0 else { throw MediaSendError(code: number) }
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
