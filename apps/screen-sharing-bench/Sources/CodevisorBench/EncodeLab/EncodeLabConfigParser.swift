import Foundation

enum EncodeLabConfigParser {
  static func parse(list: String) throws -> [EncodeLabConfig] {
    let specs = list.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !specs.isEmpty else { throw BenchUsageError(message: "--configs needs at least one config") }

    return try specs.map(parse(spec:))
  }

  static func parse(spec: String) throws -> EncodeLabConfig {
    var config = EncodeLabConfig()
    var given: Set<String> = []
    for pair in spec.split(separator: ",") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { throw invalid(spec, "\(pair) is not key=value") }

      try apply(key: parts[0], value: parts[1], to: &config, spec: spec)
      given.insert(parts[0])
    }
    applyProductDefaults(to: &config, except: given)
    try validate(config, spec: spec)
    return config
  }

  private static func applyProductDefaults(to config: inout EncodeLabConfig, except given: Set<String>) {
    let tunedElsewhere = config.preset != nil || config.constantQuality != nil
    if !given.contains("rc") { config.rateControl = config.codec == .hevc444 ? .standard : .lowLatency }
    if !given.contains("mbps") && tunedElsewhere { config.megabitsPerSecond = nil }
    guard !given.contains("speed") else { return }

    config.prioritizeSpeed = config.preset == nil && config.engine == .videoToolbox && config.rateControl == .standard
  }

  private static func apply(key: String, value: String, to config: inout EncodeLabConfig, spec: String) throws {
    if try applyShape(key: key, value: value, to: &config, spec: spec) { return }
    if try applyRate(key: key, value: value, to: &config, spec: spec) { return }
    throw invalid(spec, "unknown key \(key)")
  }

  private static func applyShape(
    key: String, value: String, to config: inout EncodeLabConfig, spec: String
  ) throws -> Bool {
    switch key {
    case "name": config.name = value
    case "engine": config.engine = try engine(value, spec: spec)
    case "codec": config.codec = try codec(value, spec: spec)
    case "size": (config.width, config.height) = try size(value, spec: spec)
    case "tiles": config.tiles = try integer(value, in: 1...16, spec: spec)
    case "skip": config.skipCleanTiles = try bool(value, spec: spec)
    case "ltr": config.longTermReferences = try bool(value, spec: spec)
    case "yuv": config.feedsYCbCr = try bool(value, spec: spec)
    case "speed": config.prioritizeSpeed = try bool(value, spec: spec)
    default: return false
    }
    return true
  }

  private static func applyRate(
    key: String, value: String, to config: inout EncodeLabConfig, spec: String
  ) throws -> Bool {
    switch key {
    case "rc": config.rateControl = try rateControl(value, spec: spec)
    case "mbps": config.megabitsPerSecond = value == "none" ? nil : try number(value, spec: spec)
    case "mfd": config.maxFrameDelay = try integer(value, in: 0...16, spec: spec)
    case "qpmax": config.maxQP = try integer(value, in: 1...51, spec: spec)
    case "qpmin": config.minQP = try integer(value, in: 1...51, spec: spec)
    case "drl": config.rateLimit = try rateLimit(value, spec: spec)
    case "preset": config.preset = value
    case "cq": config.constantQuality = try fraction(value, spec: spec)
    case "aq": config.spatialAdaptiveQP = try bool(value, spec: spec)
    case "refine": config.refinements = try integer(value, in: 0...30, spec: spec)
    case "vcpin": config.vcpInput = try fourCharacterCode(value, spec: spec)
    case "ackms": config.ackMilliseconds = try integer(value, in: 0...500, spec: spec)
    default: return false
    }
    return true
  }

  private static func validate(_ config: EncodeLabConfig, spec: String) throws {
    guard config.height.isMultiple(of: config.tiles * 2) else {
      throw invalid(spec, "height \(config.height) doesn't split into \(config.tiles) even tiles")
    }
    guard config.engine == .videoToolbox || (config.codec == .hevc444 && config.tiles <= 4) else {
      throw invalid(spec, "engine=vcp encodes hevc444 in 1 to 4 tiles")
    }
    guard config.megabitsPerSecond != nil || config.constantQuality != nil || config.preset != nil else {
      throw invalid(spec, "mbps=none needs cq or a preset")
    }
  }

  private static func codec(_ value: String, spec: String) throws -> EncodeLabCodec {
    guard let codec = EncodeLabCodec(rawValue: value) else { throw invalid(spec, "codec \(value)") }

    return codec
  }

  private static func fourCharacterCode(_ value: String, spec: String) throws -> String {
    guard value.utf8.count == 4 else { throw invalid(spec, "vcpin \(value) is not a four-character code") }

    return value
  }

  private static func engine(_ value: String, spec: String) throws -> EncodeLabEngine {
    guard let engine = EncodeLabEngine(rawValue: value) else { throw invalid(spec, "engine \(value)") }

    return engine
  }

  private static func rateControl(_ value: String, spec: String) throws -> EncodeLabRateControl {
    guard let rateControl = EncodeLabRateControl(rawValue: value) else { throw invalid(spec, "rc \(value)") }

    return rateControl
  }

  private static func size(_ value: String, spec: String) throws -> (Int, Int) {
    let parts = value.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts.allSatisfy({ $0 >= 64 && $0.isMultiple(of: 2) }) else {
      throw invalid(spec, "size \(value)")
    }

    return (parts[0], parts[1])
  }

  private static func rateLimit(_ value: String, spec: String) throws -> EncodeLabRateLimit {
    let parts = value.split(separator: "@").map(String.init)
    guard parts.count == 2 else { throw invalid(spec, "drl \(value) is not <mbps>@<seconds>") }

    return EncodeLabRateLimit(
      megabitsPerSecond: try number(parts[0], spec: spec), windowSeconds: try number(parts[1], spec: spec))
  }

  private static func integer(_ value: String, in range: ClosedRange<Int>, spec: String) throws -> Int {
    guard let parsed = Int(value), range.contains(parsed) else { throw invalid(spec, "\(value) not in \(range)") }

    return parsed
  }

  private static func number(_ value: String, spec: String) throws -> Double {
    guard let parsed = Double(value), parsed > 0 else { throw invalid(spec, "\(value) is not a positive number") }

    return parsed
  }

  private static func fraction(_ value: String, spec: String) throws -> Double {
    guard let parsed = Double(value), (0...1).contains(parsed) else { throw invalid(spec, "\(value) is not in 0...1") }

    return parsed
  }

  private static func bool(_ value: String, spec: String) throws -> Bool {
    switch value {
    case "1", "true", "on": true
    case "0", "false", "off": false
    default: throw invalid(spec, "\(value) is not 0 or 1")
    }
  }

  private static func invalid(_ spec: String, _ problem: String) -> BenchUsageError {
    BenchUsageError(message: "--configs entry \"\(spec)\": \(problem)")
  }
}
