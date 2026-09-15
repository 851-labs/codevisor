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

/// Immutable ownership of a decoded CVPixelBuffer; retaining it prevents its
/// pool from recycling the storage before Metal has finished reading it.
public struct ScreenSharingVideoFrame: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let timestampNs: Int64
  public let rtpTimestamp: UInt32
  /// Receiver-local Core Animation clock, recorded at the native RTC renderer.
  /// Never compare this with a sender timestamp or a remote clock.
  public let receivedAtSeconds: Double?
  /// Content identity: the capture timestamp of the buffer's content. Equal to
  /// `timestampNs` for a fresh capture, retained across refreshes, carried
  /// in-band to the viewer. Compare only with host values.
  public let sourceTimestampNs: Int64?
  /// Receiver-only diagnostic identity read from the decoded buffer's audit
  /// attachment at the RTC renderer callback; nil whenever the audit is off.
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
  /// Content identity written into the frame's marker.
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

/// A one-element mailbox. A slow renderer retains the newest frame, never an
/// unbounded backlog. GPU in-flight ownership is managed by the renderer.
public final class ScreenSharingFrameMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var frame: ScreenSharingVideoFrame?
  private var replacements = 0
  private var onAvailable: (@Sendable () -> Void)?

  public init() {}

  /// Newest-frame policy unchanged: returns the frame that was replaced (if
  /// any) so a receiver-only audit can record the replacement; callers that
  /// ignore it drop it exactly as before.
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

  /// Notify only the empty-to-full transition, bounding scheduled render work.
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
  /// Non-mutating ownership observation (diagnostic).
  public var isHolding: Bool { lock.withLock { frame != nil } }
}
