import ScreenSharingBench

enum Tier2V2Readings {
  static func stages(viewer: [String: JSONValue]?, host: [String: JSONValue]?, engineV2: Bool) -> BenchStageTimings? {
    guard let timeline = viewer?["timeline"]?["stages"] else { return nil }

    var stages = BenchStageTimings()
    stages.capture = distribution(timeline["capture"])
    stages.captureQueue = distribution(timeline["hostQueue"])
    stages.encode = distribution(timeline["encode"])
    stages.decodeQueue = distribution(timeline["jitterBuffer"])
    stages.decode = distribution(timeline["decode"])
    stages.renderQueue = distribution(timeline["renderQueue"])
    stages.present = distribution(timeline["present"])
    guard engineV2 else { return stages }

    var media = BenchMediaStages()
    media.queue = distribution(host?["timings"]?["sendQueue"])
    media.send = distribution(host?["timings"]?["send"])
    media.assemble = distribution(viewer?["timings"]?["assemble"])
    stages.media = media
    return stages
  }

  static func counters(viewer: [String: JSONValue]?, host: [String: JSONValue]?) -> BenchMediaCounters? {
    guard let host, let viewer else { return nil }

    return V2MediaCounters.make(
      host: integers(host["counters"]), viewer: integers(viewer["counters"]), hostMedia: numbers(host["media"]),
      viewerMedia: numbers(viewer["media"]))
  }

  private static func distribution(_ timing: JSONValue?) -> BenchDistribution? {
    guard let count = timing?["count"]?.number, let p50 = timing?["p50_ms"]?.number,
      let p95 = timing?["p95_ms"]?.number, let max = timing?["maximum_ms"]?.number
    else { return nil }

    return BenchDistribution(count: Int(count), p50: p50, p95: p95, max: max)
  }

  private static func numbers(_ value: JSONValue?) -> [String: Double] {
    guard case .object(let object)? = value else { return [:] }

    return object.compactMapValues(\.number)
  }

  private static func integers(_ value: JSONValue?) -> [String: Int] {
    numbers(value).mapValues { Int($0) }
  }
}
