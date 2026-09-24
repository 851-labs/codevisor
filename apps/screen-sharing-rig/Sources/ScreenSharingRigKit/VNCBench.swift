import Foundation

/// What `vnc-bench` measures per run (docs/plans/vnc-validation.md).
/// `CodingKeyRepresentable` so per-metric dictionaries encode as JSON objects.
public enum VNCBenchMetric: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable, Comparable {
  case updatesPerSecond
  case updateLatencyP50Ms
  case updateLatencyP95Ms
  case inputLatencyP50Ms
  case inputLatencyP95Ms
  case bytesPerUpdate
  case megabitsPerSecond
  case cpuMsPerUpdate
  case bytesCopiedPerUpdate
  /// The client's estimate of the link (851-2331): bytes that arrived while it
  /// waited for the network over that wait. Reported, not judged; on a shaped
  /// link it should read close to the profile's rate.
  case linkEstimateMbps

  public enum Direction: Sendable { case higherIsBetter, lowerIsBetter, informational }

  /// CPU per update is reported, not judged: whole-process CPU time (timers,
  /// shaping, pacing included) read 0.54, 1.22, 1.45 and 1.7 ms for the same
  /// build across runs (851-2320), more than any change moves it. Gate on the
  /// exact counts (bytes, bytes copied) and on rates and latencies instead.
  public var direction: Direction {
    switch self {
    case .updatesPerSecond: .higherIsBetter
    case .megabitsPerSecond, .cpuMsPerUpdate, .linkEstimateMbps: .informational
    default: .lowerIsBetter
    }
  }

  /// Changes smaller than this, in the metric's unit, are noise whatever the ratio.
  public var absoluteFloor: Double {
    switch self {
    case .updateLatencyP50Ms, .updateLatencyP95Ms, .inputLatencyP50Ms, .inputLatencyP95Ms: 1
    // Paced scenes leave ~16 ms idle per update; sub-ms CPU/update moves with
    // scheduling (A/A typing/lan: 0.47 → 0.91 ms, spread ±56 %).
    case .cpuMsPerUpdate: 0.5
    case .updatesPerSecond: 0.5
    case .bytesPerUpdate, .bytesCopiedPerUpdate: 64
    case .megabitsPerSecond, .linkEstimateMbps: 0.1
    }
  }

  /// The smallest noise band for this metric. Client CPU per update is
  /// mostly idle overhead on high-latency profiles (few updates share the
  /// same background timers) and moves with machine load: an unchanged build
  /// read +13 % and +19 % at load ≈ 7 (851-2328), so it gets 25 %.
  public var minimumRelativeNoise: Double {
    self == .cpuMsPerUpdate ? 0.25 : VNCBenchComparison.minimumNoise
  }

  public var label: String {
    switch self {
    case .updatesPerSecond: "updates/s"
    case .updateLatencyP50Ms: "update p50 ms"
    case .updateLatencyP95Ms: "update p95 ms"
    case .inputLatencyP50Ms: "input p50 ms"
    case .inputLatencyP95Ms: "input p95 ms"
    case .bytesPerUpdate: "bytes/update"
    case .megabitsPerSecond: "Mbit/s"
    case .cpuMsPerUpdate: "CPU ms/update"
    case .bytesCopiedPerUpdate: "copied/update"
    case .linkEstimateMbps: "link est. Mbit/s"
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
  }
}

public enum VNCBenchStatistics {
  /// Nearest-rank percentile; nil for no values.
  public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
  }

  public static func median(_ values: [Double]) -> Double? { percentile(values, 0.5) }
}

/// One scene under one network profile, over N runs.
public struct VNCBenchCase: Codable, Equatable, Sendable {
  public var scene: String
  public var profile: String
  public var runs: [[VNCBenchMetric: Double]]
  /// Per metric, the median across runs.
  public var median: [VNCBenchMetric: Double]
  /// Per metric, the largest relative distance of a run from the median: the noise band.
  public var spread: [VNCBenchMetric: Double]

  public var key: String { "\(scene)/\(profile)" }

  public init(scene: String, profile: String, runs: [[VNCBenchMetric: Double]]) {
    self.scene = scene
    self.profile = profile
    self.runs = runs
    var median: [VNCBenchMetric: Double] = [:]
    var spread: [VNCBenchMetric: Double] = [:]
    for metric in VNCBenchMetric.allCases {
      let values = runs.compactMap { $0[metric] }
      guard let middle = VNCBenchStatistics.median(values) else { continue }
      median[metric] = middle
      spread[metric] = middle == 0 ? 0 : values.map { abs($0 - middle) / abs(middle) }.max() ?? 0
    }
    self.median = median
    self.spread = spread
  }
}

public struct VNCBenchReport: Codable, Equatable, Sendable {
  public struct Machine: Codable, Equatable, Sendable {
    public var model: String
    public var system: String
    public var power: String
    /// One-minute load average when the run started; nil in older reports.
    public var load: Double?
    public init(model: String, system: String, power: String, load: Double? = nil) {
      self.model = model
      self.system = system
      self.power = power
      self.load = load
    }
  }

  public var machine: Machine
  public var build: String
  public var cases: [VNCBenchCase]

  public init(machine: Machine, build: String, cases: [VNCBenchCase]) {
    self.machine = machine
    self.build = build
    self.cases = cases
  }

  public func json() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  public func markdown() -> String {
    let metrics = VNCBenchMetric.allCases.filter { metric in cases.contains { $0.median[metric] != nil } }
    var lines = [
      "# vnc-bench", "",
      "Machine: \(machine.model), macOS \(machine.system), \(machine.power)"
        + (machine.load.map { String(format: ", load %.1f", $0) } ?? "") + ". Build: `\(build)`.",
      machine.load.map { $0 > Double(ProcessInfo.processInfo.activeProcessorCount) / 2 } == true
        ? "\n**Busy machine:** load is above half the cores; expect wider spreads." : "",
      "Median of \(cases.first?.runs.count ?? 0) run(s) per case; ± is the noise band (largest run deviation).", "",
      "| scene | profile | " + metrics.map(\.label).joined(separator: " | ") + " |",
      "| --- | --- | " + metrics.map { _ in "---:" }.joined(separator: " | ") + " |",
    ]
    for result in cases {
      let cells = metrics.map { metric -> String in
        guard let value = result.median[metric] else { return "–" }
        let spread = (result.spread[metric] ?? 0) * 100
        return "\(Self.format(value)) ±\(String(format: "%.0f", spread))%"
      }
      lines.append("| \(result.scene) | \(result.profile) | " + cells.joined(separator: " | ") + " |")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  static func format(_ value: Double) -> String {
    switch abs(value) {
    case 1000...: String(format: "%.0f", value)
    case 10...: String(format: "%.1f", value)
    default: String(format: "%.2f", value)
    }
  }
}

/// A current report against a baseline: a metric regresses or improves only
/// when it moves by more than the noise band, max(both spreads, 10 %) of the
/// baseline, and by more than the metric's absolute floor. 10 %: an A/A pair
/// of 3-run medians on loopback throughput differed by 5.4 % (851-2310).
public struct VNCBenchComparison: Sendable {
  public enum Verdict: String, Sendable { case improved, regressed, withinNoise, informational }

  public struct Row: Sendable, Equatable {
    public let key: String
    public let metric: VNCBenchMetric
    public let baseline: Double
    public let current: Double
    public let tolerance: Double
    public let verdict: Verdict
  }

  public static let minimumNoise = 0.10

  public let rows: [Row]
  /// Cases present on only one side, "scene/profile".
  public let unmatched: [String]

  public var regressions: [Row] { rows.filter { $0.verdict == .regressed } }
  public var improvements: [Row] { rows.filter { $0.verdict == .improved } }

  public init(baseline: VNCBenchReport, current: VNCBenchReport) {
    let base = Dictionary(baseline.cases.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    let now = Dictionary(current.cases.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    unmatched = Set(base.keys).symmetricDifference(now.keys).sorted()
    var rows: [Row] = []
    for key in base.keys.filter({ now[$0] != nil }).sorted() {
      let (before, after) = (base[key]!, now[key]!)
      for metric in VNCBenchMetric.allCases {
        guard let old = before.median[metric], let new = after.median[metric] else { continue }
        let band = max(before.spread[metric] ?? 0, after.spread[metric] ?? 0, metric.minimumRelativeNoise)
        let tolerance = max(abs(old) * band, metric.absoluteFloor)
        let change = new - old
        let verdict: Verdict
        switch metric.direction {
        case .informational: verdict = .informational
        case _ where abs(change) <= tolerance: verdict = .withinNoise
        case .higherIsBetter: verdict = change > 0 ? .improved : .regressed
        case .lowerIsBetter: verdict = change < 0 ? .improved : .regressed
        }
        rows.append(
          Row(key: key, metric: metric, baseline: old, current: new, tolerance: tolerance, verdict: verdict))
      }
    }
    self.rows = rows
  }

  public func markdown() -> String {
    var lines = [
      "| case | metric | baseline | current | change | verdict |", "| --- | --- | ---: | ---: | ---: | --- |",
    ]
    for row in rows where row.verdict != .informational {
      let change = row.baseline == 0 ? 0 : (row.current - row.baseline) / abs(row.baseline) * 100
      lines.append(
        "| \(row.key) | \(row.metric.label) | \(VNCBenchReport.format(row.baseline)) | "
          + "\(VNCBenchReport.format(row.current)) | \(String(format: "%+.0f", change))% | \(row.verdict.rawValue) |")
    }
    if !unmatched.isEmpty {
      lines.append(contentsOf: ["", "Not compared (one side only): \(unmatched.joined(separator: ", "))"])
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

/// `screen-sharing-rig vnc-bench` arguments.
public struct VNCBenchOptions: Sendable, Equatable {
  public static let sceneNames = ["typing", "scroll", "windowDrag", "photo", "resize", "input"]
  public static let profileNames = ["lan", "wan40", "wan150", "constrained"]

  public var scenes = ["typing", "scroll", "photo", "input"]
  public var profiles = ["lan", "wan150"]
  public var runs = 3
  public var frames = 40
  public var width = 1280
  public var height = 800
  public var seed: UInt64 = 1
  /// Scene frames per second (a real app's pace); 0 plays one frame per request, as fast as the client asks.
  public var pace = 60
  /// A fixed Tight JPEG quality 0…9 for the client; nil asks for lossless (851-2313).
  public var quality: Int?
  public var output: String?
  public var baseline: String?
  public var build = "unknown"

  public init(arguments: [String]) throws {
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      func value() throws -> String {
        guard let value = iterator.next() else { throw VNCBenchError("\(argument) needs a value") }
        return value
      }
      func list(_ allowed: [String]) throws -> [String] {
        let items = try value().split(separator: ",").map(String.init)
        if let unknown = items.first(where: { !allowed.contains($0) }) {
          throw VNCBenchError(
            "unknown \(argument.dropFirst(2)) \(unknown); choose from \(allowed.joined(separator: ", "))")
        }
        return items
      }
      func positive() throws -> Int {
        guard let number = Int(try value()), number > 0 else {
          throw VNCBenchError("\(argument) needs a positive number")
        }
        return number
      }
      switch argument {
      case "--scenes": scenes = try list(Self.sceneNames)
      case "--profiles": profiles = try list(Self.profileNames)
      case "--runs": runs = try positive()
      case "--frames": frames = try positive()
      case "--seed": seed = UInt64(try positive())
      case "--quality":
        guard let number = Int(try value()), (0...9).contains(number) else {
          throw VNCBenchError("--quality needs 0…9")
        }
        quality = number
      case "--pace":
        guard let number = Int(try value()), (0...240).contains(number) else {
          throw VNCBenchError("--pace needs 0…240 (0: one frame per request)")
        }
        pace = number
      case "--size":
        let parts = try value().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { throw VNCBenchError("--size expects WIDTHxHEIGHT") }
        (width, height) = (parts[0], parts[1])
      case "--out": output = try value()
      case "--baseline": baseline = try value()
      case "--build": build = try value()
      default: throw VNCBenchError("unknown argument \(argument)")
      }
    }
  }
}

/// The `vnc-server` process a bench case runs against.
public enum VNCBenchServer {
  /// Arguments for one case. `pace` 0 plays a scene frame per incremental
  /// request (851-2336): that only works if the client keeps requesting, so
  /// the server offers no continuous updates (`--requested-only`). Otherwise
  /// the client switches to pushed updates, stops requesting, and the run
  /// waits forever.
  public static func arguments(
    scene: String, echo: Bool, seed: UInt64, pace: Int, width: Int, height: Int
  ) -> [String] {
    [
      "vnc-server", "--port", "0", "--no-password", "--size", "\(width)x\(height)", "--scene", scene, "--seed",
      "\(seed)",
    ]
      + (echo ? ["--echo"] : []) + (pace > 0 ? ["--scene-fps", "\(pace)"] : ["--requested-only"])
  }
}

public struct VNCBenchError: LocalizedError {
  public let errorDescription: String?
  public init(_ message: String) { errorDescription = message }
}
