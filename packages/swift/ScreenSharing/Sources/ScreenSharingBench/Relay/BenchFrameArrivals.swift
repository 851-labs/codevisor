public struct BenchFrameArrivals: Sendable {
  private var deliveredNs: [UInt32: [Int64]] = [:]

  public init() {}

  public mutating func record(_ bytes: [UInt8], deliveredAtNs nowNs: Int64) {
    guard let header = BenchRtpHeader(bytes), !header.hasPadding else { return }

    deliveredNs[header.timestamp, default: []].append(nowNs)
  }

  public func completedNs(rtpTimestamp: UInt32, byNs decodeInputNs: Int64) -> Int64? {
    deliveredNs[rtpTimestamp]?.filter { $0 <= decodeInputNs }.max()
  }
}
