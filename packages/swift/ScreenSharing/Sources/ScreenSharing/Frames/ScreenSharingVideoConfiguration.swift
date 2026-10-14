import CoreVideo
import Foundation

public enum ScreenSharingError: Error, LocalizedError, Sendable {
  case unavailable(String)
  case invalid(String)
  case codec(String, Int32)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message), .invalid(let message): message
    case .codec(let operation, let status): "\(operation) failed (\(status))."
    }
  }
}

public struct ScreenSharingVideoConfiguration: Sendable, Equatable, Codable {
  public let width: Int
  public let height: Int
  public let framesPerSecond: Int
  public let bitrate: Int

  public init(width: Int = 1920, height: Int = 1080, framesPerSecond: Int = 60, bitrate: Int = 12_000_000) throws {
    guard (64...3840).contains(width), (64...2160).contains(height), width.isMultiple(of: 2), height.isMultiple(of: 2),
      (1...60).contains(framesPerSecond), (100_000...80_000_000).contains(bitrate)
    else { throw ScreenSharingError.invalid("Unsupported video dimensions, frame rate or bitrate.") }
    self.width = width
    self.height = height
    self.framesPerSecond = framesPerSecond
    self.bitrate = bitrate
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      width: values.decode(Int.self, forKey: .width), height: values.decode(Int.self, forKey: .height),
      framesPerSecond: values.decode(Int.self, forKey: .framesPerSecond),
      bitrate: values.decode(Int.self, forKey: .bitrate))
  }
}

public struct ScreenSharingVideoFrame: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let timestampNs: Int64
  public let rtpTimestamp: UInt32
  public let receivedAtSeconds: Double?
  public let sourceTimestampNs: Int64?
  public let deliveryAuditIdentity: ScreenSharingFrameDeliveryAudit.Identity?

  public init(
    pixelBuffer: CVPixelBuffer, timestampNs: Int64, rtpTimestamp: UInt32 = 0,
    receivedAtSeconds: Double? = nil, sourceTimestampNs: Int64? = nil,
    deliveryAuditIdentity: ScreenSharingFrameDeliveryAudit.Identity? = nil
  ) {
    self.pixelBuffer = pixelBuffer
    self.timestampNs = timestampNs
    self.rtpTimestamp = rtpTimestamp
    self.receivedAtSeconds = receivedAtSeconds
    self.sourceTimestampNs = sourceTimestampNs
    self.deliveryAuditIdentity = deliveryAuditIdentity
  }
}

public struct ScreenSharingEncodedFrame: Sendable {
  public let data: Data
  public let timestampNs: Int64
  public let rtpTimestamp: UInt32
  public let width: Int
  public let height: Int
  public let isKeyFrame: Bool
  public var sourceTimestampNs: Int64? = nil

  package init(
    data: Data, timestampNs: Int64, rtpTimestamp: UInt32, width: Int, height: Int, isKeyFrame: Bool,
    sourceTimestampNs: Int64? = nil
  ) {
    self.data = data
    self.timestampNs = timestampNs
    self.rtpTimestamp = rtpTimestamp
    self.width = width
    self.height = height
    self.isKeyFrame = isKeyFrame
    self.sourceTimestampNs = sourceTimestampNs
  }
}

public final class ScreenSharingFrameMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var frame: ScreenSharingVideoFrame?
  private var replacements = 0
  private var onAvailable: (@Sendable () -> Void)?

  public init() {}

  @discardableResult
  public func put(_ value: ScreenSharingVideoFrame) -> ScreenSharingVideoFrame? {
    let (notify, replaced) = lock.withLock {
      let previous = frame
      if previous != nil { replacements += 1 }
      frame = value
      return (previous == nil ? onAvailable : nil, previous)
    }
    notify?()
    return replaced
  }

  public func onFrameAvailable(_ callback: (@Sendable () -> Void)?) {
    let occupied = lock.withLock {
      onAvailable = callback; return frame != nil
    }
    if occupied { callback?() }
  }

  public func take() -> ScreenSharingVideoFrame? {
    lock.withLock {
      defer { frame = nil }
      return frame
    }
  }

  public func clear() { lock.withLock { frame = nil } }
  public var droppedFrames: Int { lock.withLock { replacements } }
  public var isHolding: Bool { lock.withLock { frame != nil } }
}
