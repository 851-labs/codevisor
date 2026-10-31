import Foundation

#if canImport(codevisor_net_ffiFFI)
  import codevisor_net_ffiFFI
#endif

public enum MediaSendError: Error, Equatable {
  case noDatagrams
  case pathTooSmall
  case metaTooLarge
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
  public func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
    try withExtendedLifetime(self) {
      var count = 0
      let start = codevisor_media_bytes(uniffiCloneHandle(), &count)
      return try body(UnsafeRawBufferPointer(start: start, count: count))
    }
  }

  public var data: Data {
    withUnsafeBytes { Data($0) }
  }
}
