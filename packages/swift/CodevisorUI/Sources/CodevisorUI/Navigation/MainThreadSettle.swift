import Foundation

public struct MainThreadSettle {
  public struct Result: Equatable, Sendable {
    public let busyNanoseconds: UInt64
    public let firstPassNanoseconds: UInt64
    public let settleNanoseconds: UInt64
    public let settled: Bool
  }

  private let start: UInt64
  private let quietNanoseconds: UInt64
  private let limitNanoseconds: UInt64
  private var awakeSince: UInt64
  private var asleepSince: UInt64?
  private var firstSleptAt: UInt64?
  private var busyNanoseconds: UInt64 = 0

  public init(start: UInt64, quietNanoseconds: UInt64, limitNanoseconds: UInt64) {
    self.start = start
    self.quietNanoseconds = quietNanoseconds
    self.limitNanoseconds = limitNanoseconds
    awakeSince = start
  }

  public mutating func willSleep(at now: UInt64) {
    guard asleepSince == nil else { return }

    busyNanoseconds += now - awakeSince
    asleepSince = now
    if firstSleptAt == nil { firstSleptAt = now }
  }

  public mutating func didWake(at now: UInt64) -> Result? {
    guard let asleepSince else { return nil }

    self.asleepSince = nil
    awakeSince = now
    if now - asleepSince >= quietNanoseconds { return result(endingAt: asleepSince, settled: true) }
    if now - start >= limitNanoseconds { return result(endingAt: now, settled: false) }
    return nil
  }

  private func result(endingAt end: UInt64, settled: Bool) -> Result {
    Result(
      busyNanoseconds: busyNanoseconds, firstPassNanoseconds: (firstSleptAt ?? end) - start,
      settleNanoseconds: end - start, settled: settled)
  }
}
