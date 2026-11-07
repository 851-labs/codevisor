import Foundation
import ScreenSharingBench

struct Tier2RunFiles {
  let directory: URL
  let meta: Tier2RunMeta
  let host: [BenchObservation]?
  let viewer: [BenchObservation]
  let hostBottom: [BenchObservation]?
  let viewerBottom: [BenchObservation]?
  let clockBursts: [[BenchClockExchange]]
  let hostUsage: [BenchUsageSecond]
  let viewerUsage: [BenchUsageSecond]
  let preflights: [String: Tier2Preflight]
  let system: [String: JSONValue]?
  let share: [String: JSONValue]?
  let networkCheck: [String: JSONValue]?
  let hostSample: [String: JSONValue]?
  let viewerSample: [String: JSONValue]?
  let inputEvents: [BenchInputEvent]?
  let inject: [String: JSONValue]?

  init(directory: URL) throws {
    self.directory = directory
    meta = try Self.snakeCase.decode(Tier2RunMeta.self, from: Data(contentsOf: directory.appending(path: "meta.json")))
    host = try Self.optional(directory, "host.jsonl").map { try BenchObserverLog(jsonLines: $0).observations }
    viewer = try BenchObserverLog(jsonLines: Data(contentsOf: directory.appending(path: "viewer.jsonl"))).observations
    hostBottom = try Self.optional(directory, "host-bottom.jsonl").map {
      try BenchObserverLog(jsonLines: $0).observations
    }
    viewerBottom = try Self.optional(directory, "viewer-bottom.jsonl").map {
      try BenchObserverLog(jsonLines: $0).observations
    }
    clockBursts = try Self.bursts(Data(contentsOf: directory.appending(path: "clock.jsonl")))
    hostUsage = try Self.lines(BenchUsageSecond.self, Self.optional(directory, "host-usage.jsonl"), Self.plain)
    viewerUsage = try Self.lines(BenchUsageSecond.self, Self.optional(directory, "viewer-usage.jsonl"), Self.plain)
    preflights = try Self.preflights(directory)
    networkCheck = Self.optional(directory, "network-check.json").flatMap {
      try? Self.plain.decode([String: JSONValue].self, from: $0)
    }
    hostSample = Self.optional(directory, "host-sample.json").flatMap {
      try? Self.plain.decode([String: JSONValue].self, from: $0)
    }
    viewerSample = Self.optional(directory, "viewer-sample.json").flatMap {
      try? Self.plain.decode([String: JSONValue].self, from: $0)
    }
    share = Self.optional(directory, "share.json").flatMap {
      try? Self.plain.decode([String: JSONValue].self, from: $0)
    }
    system = Self.optional(directory, "system.json").flatMap {
      try? Self.plain.decode([String: JSONValue].self, from: $0)
    }
    inputEvents = try Self.optional(directory, "input-events.jsonl").map {
      try Self.lines(BenchInputEvent.self, $0, Self.plain)
    }
    inject = Self.optional(directory, "inject.json").flatMap {
      try? Self.plain.decode([String: JSONValue].self, from: $0)
    }
  }

  private static let ownRunnerJobs = 1

  var ciBusy: Bool {
    preflights.values.contains { $0.ciJobs > Self.ownRunnerJobs }
  }

  var preflightProblems: [String] {
    preflights.keys.sorted().flatMap { preflights[$0]?.problems ?? [] }
  }

  var hpSessionOnScreen: Bool {
    system?["session_on_screen"]?.bool == true
  }

  var hpFocusLosses: Int? {
    system?["focus_losses"]?.number.map { Int($0) }
  }

  var ranHighPerformance: Bool {
    system?["chose_high_performance"]?.bool == true
  }

  var shapedPathProven: Bool {
    switch meta.system {
    case .appleHP: Self.allIPv4(preflights["host-during-preflight.json"]?.screenSharingPeers ?? [])
    case .codevisor, .codevisorV2, .codevisorV2VCP: (candidateRoundTripS ?? 0) >= Self.shapedRoundTripS
    case .floor: true
    }
  }

  private static let shapedRoundTripS = 0.0015

  private var candidateRoundTripS: Double? {
    guard case .object(let candidates)? = system?["selected_candidates"] else { return nil }

    return candidates.first { $0.key.hasSuffix(".currentRoundTripTime") }?.value.string.flatMap(Double.init)
  }

  private static func allIPv4(_ peers: [String]) -> Bool {
    !peers.isEmpty && peers.allSatisfy { !$0.contains(":") }
  }

  var systemCpuPct: BenchResult.PerMachine<Double>? {
    let host = hostSample?["all_processes"]?["cpu_pct"]?.number
    let viewer = viewerSample?["all_processes"]?["cpu_pct"]?.number
    guard host != nil || viewer != nil else { return nil }

    return BenchResult.PerMachine(host: host, viewer: viewer)
  }

  var realizedNetwork: BenchResult.NetworkCheck? {
    guard let probes = networkCheck?["probes"]?.number, probes > 0, let replies = networkCheck?["replies"]?.number
    else { return nil }

    return BenchResult.NetworkCheck(
      probes: Int(probes), replies: Int(replies),
      roundTripMs: networkCheck?["burst_minimum_round_trip_ms"]?["p50"]?.number)
  }

  var hostDisplayDuringRun: String? {
    preflights["host-during-preflight.json"]?.mainDisplay
  }

  var highestLoad: Double? {
    preflights.values.map(\.load1).max()
  }

  private static let plain = JSONDecoder()
  private static let snakeCase: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  private static func optional(_ directory: URL, _ name: String) -> Data? {
    try? Data(contentsOf: directory.appending(path: name))
  }

  private static func lines<Line: Decodable>(_ type: Line.Type, _ data: Data?, _ decoder: JSONDecoder) throws -> [Line]
  {
    guard let data else { return [] }

    return try data.split(separator: UInt8(ascii: "\n")).map { try decoder.decode(Line.self, from: Data($0)) }
  }

  private static func bursts(_ data: Data) throws -> [[BenchClockExchange]] {
    let records = try lines(ProbeLine.self, data, snakeCase)
    let grouped = Dictionary(grouping: records, by: \.burst)
    return grouped.keys.sorted().map { grouped[$0, default: []].map(\.exchange) }
  }

  private static func preflights(_ directory: URL) throws -> [String: Tier2Preflight] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0.hasSuffix("-preflight.json")
    }
    var preflights: [String: Tier2Preflight] = [:]
    for name in names {
      preflights[name] = try? snakeCase.decode(
        Tier2Preflight.self, from: Data(contentsOf: directory.appending(path: name)))
    }
    return preflights
  }
}

private struct ProbeLine: Decodable {
  let burst: Int
  let localSendNs: Int64
  let remoteReceiveNs: Int64
  let remoteSendNs: Int64
  let localReceiveNs: Int64

  var exchange: BenchClockExchange {
    BenchClockExchange(
      localSendNs: localSendNs, remoteReceiveNs: remoteReceiveNs, remoteSendNs: remoteSendNs,
      localReceiveNs: localReceiveNs)
  }
}
