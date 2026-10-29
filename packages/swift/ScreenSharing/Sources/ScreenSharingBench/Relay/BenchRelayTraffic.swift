public struct BenchRelayTraffic: Sendable, Equatable {
  private static let windowNs: Int64 = 1_000_000_000
  private static let bitsPerByte = 8.0
  private static let bytesPerMegabyte = 1_000_000.0

  private let originNs: Int64
  private var bytesPerWindow: [Int] = []

  init(originNs: Int64) {
    self.originNs = originNs
  }

  mutating func record(byteCount: Int, atNs sentNs: Int64) {
    guard sentNs >= originNs else { return }

    let window = Int((sentNs - originNs) / Self.windowNs)
    if bytesPerWindow.count <= window {
      bytesPerWindow += Array(repeating: 0, count: window + 1 - bytesPerWindow.count)
    }
    bytesPerWindow[window] += byteCount
  }

  public func bitrate(fromSecond first: Int, toSecond end: Int) -> BenchResult.Bitrate? {
    let windows = (first..<max(first, end)).map { $0 < bytesPerWindow.count ? bytesPerWindow[$0] : 0 }
    guard let megabits = BenchDistribution(windows.map { Double($0) * Self.bitsPerByte / Self.bytesPerMegabyte })
    else { return nil }

    let totalMb = Double(windows.reduce(0, +)) / Self.bytesPerMegabyte
    return BenchResult.Bitrate(p50: megabits.p50, p95: megabits.p95, max: megabits.max, totalMb: totalMb)
  }
}
