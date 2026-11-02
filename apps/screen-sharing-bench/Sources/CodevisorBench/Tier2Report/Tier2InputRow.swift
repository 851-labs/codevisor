import ScreenSharingBench

struct Tier2InputRow {
  struct Key: Hashable {
    let resolution: String
    let network: String
    let system: BenchSystem
  }

  let key: Key
  private let all: [Tier2Measurement]
  private let valid: [Tier2Measurement]

  init(key: Key, measurements: [Tier2Measurement]) {
    self.key = key
    all = measurements
    valid = measurements.filter { $0.invalidReason == nil }
  }

  var p50: Double? {
    median { $0.answered?.p50 }
  }

  var p95: Double? {
    median { $0.answered?.p95 }
  }

  func cells(floors: Tier2InputFloors, appleP50: Double?) -> [String] {
    let numbers = [
      median { Double($0.events) }, median { Double($0.answered?.count ?? 0) }, p50, p95,
      valid.compactMap { $0.inputToPhoton?.answered?.max }.max(), median { $0.byKind[.key]?.p50 },
      median { $0.byKind[.click]?.p50 }, difference(p50, floors.p50(network: key.network)),
      difference(p95, floors.p95(network: key.network)), difference(p50, appleP50),
    ]
    return [key.resolution, key.network, key.system.rawValue] + numbers.map(Tier2Format.number)
      + ["\(valid.count)/\(all.count)"]
  }

  private func median(_ value: (BenchInputToPhoton) -> Double?) -> Double? {
    BenchSystemComparison.median(valid.compactMap { $0.inputToPhoton.flatMap(value) })
  }

  private func difference(_ value: Double?, _ reference: Double?) -> Double? {
    guard let value, let reference else { return nil }

    return value - reference
  }
}
