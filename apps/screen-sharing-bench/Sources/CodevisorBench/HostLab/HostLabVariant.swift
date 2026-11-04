import ScreenSharing
import ScreenSharingV2

struct HostLabVariant: Equatable, Sendable {
  private static let keys = ["queue", "cursor", "fps", "refine", "converge", "tiles", "ltr", "vcp", "bgra"]
  private static let queueDepths = 1...8
  private static let rates = 1...120
  private static let passes = 0...12
  private static let convergedBytes = 0...1_000_000
  private static let tileCounts = [1, ScreenSharingV2Profile.tileCount]
  static let usage =
    "queue=<1-8>,cursor=0|1,fps=<1-120>,refine=<0-12>,converge=<bytes>,tiles=1|4,ltr=0|1,vcp=0|1,bgra=0|1, "
    + "or base"

  var name = "base"
  var queueDepth = ScreenSharingCapture.defaultQueueDepth
  var showsCursor = true
  var framesPerSecond = ScreenSharingV2Profile.framesPerSecond
  var refinement: ScreenSharingV2RefinementPolicy?
  var tiles: Int?
  var longTermReferences = true
  var encoder = ScreenSharingV2EncoderKind.videoToolbox
  var capturesBGRA = false

  init() {}

  init(parsing text: String) throws {
    name = text
    guard text != "base" else { return }

    for pair in text.split(separator: ",") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2, let value = Int(parts[1]) else {
        throw BenchUsageError(message: "variant settings are key=value, not \(pair)")
      }

      try set(parts[0], to: value)
    }
  }

  @MainActor init(options: BenchOptions) throws {
    for key in Self.keys {
      guard let text = try options.string(key) else { continue }
      guard let value = Int(text) else { throw BenchUsageError(message: "--\(key) takes a number, not \(text)") }

      try set(key, to: value)
    }
    name = try options.string("variant", default: name)
  }

  var arguments: [String] {
    var arguments = [
      "--variant", name, "--queue", "\(queueDepth)", "--cursor", showsCursor ? "1" : "0", "--fps",
      "\(framesPerSecond)", "--ltr", longTermReferences ? "1" : "0", "--vcp", encoder == .videoProcessing ? "1" : "0", "--bgra",
      capturesBGRA ? "1" : "0",
    ]
    if let refinement {
      arguments += ["--refine", "\(refinement.passes)", "--converge", "\(refinement.convergedBelowBytes)"]
    }
    if let tiles { arguments += ["--tiles", "\(tiles)"] }
    return arguments
  }

  private mutating func set(_ key: String, to value: Int) throws {
    switch key {
    case "queue": queueDepth = try Self.check(key, value, Self.queueDepths.contains(value))
    case "cursor": showsCursor = try Self.check(key, value, [0, 1].contains(value)) == 1
    case "fps": framesPerSecond = try Self.check(key, value, Self.rates.contains(value))
    case "refine":
      var policy = refinement ?? .standard
      policy.passes = try Self.check(key, value, Self.passes.contains(value))
      refinement = policy
    case "converge":
      var policy = refinement ?? .standard
      policy.convergedBelowBytes = try Self.check(key, value, Self.convergedBytes.contains(value))
      refinement = policy
    case "tiles": tiles = try Self.check(key, value, Self.tileCounts.contains(value))
    case "ltr": longTermReferences = try Self.check(key, value, [0, 1].contains(value)) == 1
    case "vcp": encoder = try Self.check(key, value, [0, 1].contains(value)) == 1 ? .videoProcessing : .videoToolbox
    case "bgra": capturesBGRA = try Self.check(key, value, [0, 1].contains(value)) == 1
    default: throw BenchUsageError(message: "unknown variant setting \(key); use \(Self.usage)")
    }
  }

  private static func check(_ key: String, _ value: Int, _ valid: Bool) throws -> Int {
    guard valid else { throw BenchUsageError(message: "\(key)=\(value) is out of range; use \(usage)") }

    return value
  }
}
