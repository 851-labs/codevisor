public struct BenchMediaStages: Codable, Sendable, Equatable {
  private static let nanosecondsPerMillisecond = 1_000_000.0

  public var handOff: BenchDistribution?
  public var queue: BenchDistribution?
  public var send: BenchDistribution?
  public var network: BenchDistribution?
  public var assemble: BenchDistribution?
  public var recover: BenchDistribution?

  public init() {}

  public init?(frames: [BenchFrameTimestamps]) {
    let media = frames.compactMap { frame in frame.media.map { (frame, $0) } }
    guard !media.isEmpty else { return nil }

    handOff = Self.span(media) { frame, media in (frame.encodeOutputNs, media.sendNs) }
    queue = Self.span(media) { _, media in media.firstPacketOutNs.map { (media.sendNs, $0) } }
    send = Self.span(media) { _, media in
      media.firstPacketOutNs.flatMap { first in media.lastPacketOutNs.map { (first, $0) } }
    }
    network = Self.span(media) { frame, media in media.lastPacketOutNs.map { ($0, frame.decodeInputNs) } }
    assemble = Self.span(media) { frame, media in (media.firstPacketInNs, frame.decodeInputNs) }
    recover = Self.span(media.filter { $0.1.recovery != .none }) { frame, media in
      (media.firstPacketInNs, frame.decodeInputNs)
    }
  }

  private static func span(
    _ frames: [(BenchFrameTimestamps, BenchMediaFrameTimestamps)],
    _ endpoints: (BenchFrameTimestamps, BenchMediaFrameTimestamps) -> (Int64, Int64)?
  ) -> BenchDistribution? {
    BenchDistribution(frames.compactMap(endpoints).map { Double($1 - $0) / nanosecondsPerMillisecond })
  }
}
