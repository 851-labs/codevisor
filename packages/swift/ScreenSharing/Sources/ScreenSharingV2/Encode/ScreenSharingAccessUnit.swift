import CoreMedia
import Foundation

public struct ScreenSharingAccessUnit: ScreenSharingBytes, @unchecked Sendable {
  private enum Storage {
    case data(Data)
    case block(CMBlockBuffer)
  }

  private let storage: Storage

  public init(_ data: Data) {
    storage = .data(data)
  }

  init(contiguous block: CMBlockBuffer) {
    storage = .block(block)
  }

  public var count: Int {
    switch storage {
    case .data(let data): data.count
    case .block(let block): CMBlockBufferGetDataLength(block)
    }
  }

  public func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
    switch storage {
    case .data(let data): return try data.withUnsafeBytes(body)
    case .block(let block): return try Self.withBytes(of: block, body)
    }
  }

  private static func withBytes<Result>(
    of block: CMBlockBuffer, _ body: (UnsafeRawBufferPointer) throws -> Result
  ) rethrows -> Result {
    var length = 0
    var pointer: UnsafeMutablePointer<CChar>?
    let status = CMBlockBufferGetDataPointer(
      block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
    guard status == kCMBlockBufferNoErr, let pointer else { return try body(UnsafeRawBufferPointer(start: nil, count: 0)) }

    return try body(UnsafeRawBufferPointer(start: pointer, count: length))
  }
}
