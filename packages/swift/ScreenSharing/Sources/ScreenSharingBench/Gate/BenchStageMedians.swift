public struct BenchStageMedians: Codable, Sendable, Equatable {
  public var capture: Double?
  public var captureQueue: Double?
  public var encode: Double?
  public var network: Double?
  public var send: Double?
  public var decodeQueue: Double?
  public var decode: Double?
  public var renderQueue: Double?
  public var present: Double?

  public init(
    capture: Double? = nil, captureQueue: Double? = nil, encode: Double? = nil, network: Double? = nil,
    send: Double? = nil, decodeQueue: Double? = nil, decode: Double? = nil, renderQueue: Double? = nil,
    present: Double? = nil
  ) {
    self.capture = capture
    self.captureQueue = captureQueue
    self.encode = encode
    self.network = network
    self.send = send
    self.decodeQueue = decodeQueue
    self.decode = decode
    self.renderQueue = renderQueue
    self.present = present
  }

  public init(_ timings: [BenchStageTimings]) {
    capture = Self.median(timings, \.capture)
    captureQueue = Self.median(timings, \.captureQueue)
    encode = Self.median(timings, \.encode)
    network = Self.median(timings, \.networkResidual)
    send = Self.median(timings, \.send)
    decodeQueue = Self.median(timings, \.decodeQueue)
    decode = Self.median(timings, \.decode)
    renderQueue = Self.median(timings, \.renderQueue)
    present = Self.median(timings, \.present)
  }

  public var isSplitAtTheJitterBuffer: Bool {
    decodeQueue != nil
  }

  public func ordered(splitAtTheJitterBuffer split: Bool) -> [(name: String, p50Ms: Double?)] {
    let network: [(name: String, p50Ms: Double?)] =
      split ? [("send", send), ("jitter buffer", decodeQueue)] : [("network", self.network)]
    return [("capture", capture), ("capture queue", captureQueue), ("encode", encode)] + network
      + [("decode", decode), ("render queue", renderQueue), ("present", present)]
  }

  private static func median(
    _ timings: [BenchStageTimings], _ stage: KeyPath<BenchStageTimings, BenchDistribution?>
  ) -> Double? {
    BenchMedian.of(timings.compactMap { $0[keyPath: stage]?.p50 })
  }
}
