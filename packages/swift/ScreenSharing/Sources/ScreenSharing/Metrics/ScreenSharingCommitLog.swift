import Foundation

public struct ScreenSharingCommitRecord: Codable, Equatable, Sendable {
  public let committedNs: Int64
  public let rtpTimestamp: UInt32
  public let sourceTimestampNs: Int64?
  public var presentedNs: Int64?
}

public final class ScreenSharingCommitLog: @unchecked Sendable {
  public static let capacity = 4096

  private let lock = NSLock()
  private var ring = [ScreenSharingCommitRecord?](repeating: nil, count: capacity)
  private var next = 0
  private var recording = false

  package init() {}

  public var isRecording: Bool {
    get { lock.withLock { recording } }
    set { lock.withLock { recording = newValue } }
  }

  package func record(_ record: ScreenSharingCommitRecord) -> Int? {
    lock.withLock {
      guard recording else { return nil }

      ring[next % Self.capacity] = record
      next += 1
      return next - 1
    }
  }

  package func presented(_ entry: Int, atNs presentedNs: Int64) {
    lock.withLock {
      guard entry >= next - Self.capacity, entry < next else { return }

      ring[entry % Self.capacity]?.presentedNs = presentedNs
    }
  }

  public func all() -> [ScreenSharingCommitRecord] {
    lock.withLock {
      (max(0, next - Self.capacity)..<next).compactMap { ring[$0 % Self.capacity] }
    }
  }
}
