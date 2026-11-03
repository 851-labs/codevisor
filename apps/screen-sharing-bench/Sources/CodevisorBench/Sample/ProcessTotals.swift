import Darwin

struct ProcessTotals: Encodable, Equatable {
  struct Usage: Encodable, Equatable {
    let name: String
    let cpuPct: Double
  }

  static let benchExecutable = "CodevisorBench"
  private static let percent = 100.0
  private static let limit = 25

  let cpuPct: Double
  let top: [Usage]

  init?(from start: ProcessListing, to end: ProcessListing, label: (ProcessListing.Entry) -> String = Self.label) {
    let elapsedNs = Double(end.sampledNs - start.sampledNs)
    guard elapsedNs > 0 else { return nil }

    let before = Dictionary(start.entries.map { ($0.pid, $0.cpuNs) }, uniquingKeysWith: max)
    var cpuNs: [String: Int64] = [:]
    for entry in end.entries {
      let used = entry.cpuNs - (before[entry.pid] ?? 0)
      guard used > 0 else { continue }

      cpuNs[label(entry), default: 0] += used
    }
    let usage = cpuNs.map { Usage(name: $0.key, cpuPct: Double($0.value) * Self.percent / elapsedNs) }
    cpuPct = usage.map(\.cpuPct).reduce(0, +)
    top = Array(usage.sorted { ($0.cpuPct, $1.name) > ($1.cpuPct, $0.name) }.prefix(Self.limit))
  }

  static func label(_ entry: ProcessListing.Entry) -> String {
    guard entry.name == benchExecutable, let command = ProcessArguments.of(entry.pid).dropFirst().first else {
      return entry.name
    }

    return "\(entry.name):\(command)"
  }
}
