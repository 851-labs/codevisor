struct ScreenSharingV2WindowedMinimum: Sendable, Equatable {
  private struct Sample: Sendable, Equatable {
    let atNs: Int64
    let value: Double
  }

  let windowNs: Int64
  private var samples: [Sample] = []

  init(windowNs: Int64) {
    self.windowNs = windowNs
  }

  mutating func observe(_ value: Double, atNs nowNs: Int64) -> Double {
    samples.removeAll { $0.atNs < nowNs - windowNs || $0.value >= value }
    samples.append(Sample(atNs: nowNs, value: value))
    return samples[0].value
  }
}
