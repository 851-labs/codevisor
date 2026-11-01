import Foundation

public final class ScreenSharingFrameTimeline: @unchecked Sendable {
  public static let recordCapacity = 1800
  private static let decodedCapacity = 16

  private let lock = NSLock()
  private let localClock: UInt64
  private var decoded = [ScreenSharingDecodedFrameTiming?](repeating: nil, count: decodedCapacity)
  private var nextDecoded = 0
  private var records: [ScreenSharingFrameRecord?] = []
  private var lastSequence: UInt64 = 0
  private var unpresented = 0
  private var transport = ScreenSharingTransportEstimate()
  private var refreshGrid: ScreenSharingRefreshGrid?
  private var reportsPresentedTime = false

  package init(localClock: UInt64 = ScreenSharingClockIdentity.current) {
    self.localClock = localClock
  }

  public func observeTransport(_ statistics: [String: String]) {
    lock.withLock { transport.update(statistics: statistics) }
  }

  package func observeTransport(networkUs: Int64, jitterBufferUs: Int64) {
    lock.withLock { transport.update(networkUs: networkUs, jitterBufferUs: jitterBufferUs) }
  }

  package func observeRefresh(targetNs: Int64, periodNs: Int64) {
    lock.withLock { refreshGrid = ScreenSharingRefreshGrid(targetNs: targetNs, periodNs: periodNs) }
  }

  package func decoded(_ frame: ScreenSharingDecodedFrameTiming) {
    lock.withLock {
      if decoded[nextDecoded] != nil { unpresented += 1 }
      decoded[nextDecoded] = frame
      nextDecoded = (nextDecoded + 1) % Self.decodedCapacity
    }
  }

  package func presented(sourceTimestampNs: Int64, _ presentation: ScreenSharingFramePresentation) {
    lock.withLock {
      guard let frame = takeDecoded(sourceTimestampNs) else { return }

      if records.isEmpty { records = Array(repeating: nil, count: Self.recordCapacity) }
      lastSequence += 1
      records[Int((lastSequence - 1) % UInt64(Self.recordCapacity))] = ScreenSharingFrameRecord(
        sequence: lastSequence, decoded: frame, presentation: presentation, estimate: onGlassEstimate(presentation),
        transport: transport, localClock: localClock)
    }
  }

  public func records(after sequence: UInt64) -> [ScreenSharingFrameRecord] {
    lock.withLock { retained(after: sequence) }
  }

  public func summary() -> ScreenSharingFrameTimelineSummary? {
    let (records, unpresented) = lock.withLock { (retained(after: 0), unpresented) }
    return ScreenSharingFrameTimelineSummary(records: records, unpresentedFrames: unpresented)
  }

  private func onGlassEstimate(_ presentation: ScreenSharingFramePresentation) -> ScreenSharingOnGlassEstimate {
    if presentation.presentedAtNs != nil { reportsPresentedTime = true }
    let target = presentation.gpuCompletedNs.flatMap { refreshGrid?.onGlass(afterGPUCompletionAt: $0) }
    return ScreenSharingOnGlassEstimate(
      displayLinkTargetNs: target, replacesMissingPresentedTime: !reportsPresentedTime)
  }

  private func takeDecoded(_ sourceTimestampNs: Int64) -> ScreenSharingDecodedFrameTiming? {
    guard let index = newestDecodedIndex(sourceTimestampNs) else { return nil }

    defer { decoded[index] = nil }
    return decoded[index]
  }

  private func newestDecodedIndex(_ sourceTimestampNs: Int64) -> Int? {
    for age in 1...Self.decodedCapacity {
      let index = (nextDecoded - age + Self.decodedCapacity) % Self.decodedCapacity
      if decoded[index]?.sourceTimestampNs == sourceTimestampNs { return index }
    }
    return nil
  }

  private func retained(after sequence: UInt64) -> [ScreenSharingFrameRecord] {
    let oldestRetained = lastSequence - min(lastSequence, UInt64(Self.recordCapacity))
    let first = max(sequence, oldestRetained) + 1
    guard first <= lastSequence else { return [] }

    return (first...lastSequence).compactMap { records[Int(($0 - 1) % UInt64(Self.recordCapacity))] }
  }
}
