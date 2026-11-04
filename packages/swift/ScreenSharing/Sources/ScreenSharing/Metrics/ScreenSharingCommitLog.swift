import Foundation

public struct ScreenSharingCommitRecord: Codable, Equatable, Sendable {
  public let committedNs: Int64
  public let rtpTimestamp: UInt32
  public let sourceTimestampNs: Int64
  public var presentedAt: Double?
}

public final class ScreenSharingCommitLog: @unchecked Sendable {
  public static let capacity = 4096

  private let lock = NSLock()
  private var records: [ScreenSharingCommitRecord] = []
  private var first = 0

  package init() {}

  package func record(_ record: ScreenSharingCommitRecord) -> Int {
    lock.withLock {
      if records.count == Self.capacity {
        records.removeFirst()
        first += 1
      }
      records.append(record)
      return first + records.count - 1
    }
  }

  package func presented(_ entry: Int, at presentedAt: Double) {
    lock.withLock {
      let index = entry - first
      guard records.indices.contains(index) else { return }

      records[index].presentedAt = presentedAt
    }
  }

  public func all() -> [ScreenSharingCommitRecord] {
    lock.withLock { records }
  }
}
