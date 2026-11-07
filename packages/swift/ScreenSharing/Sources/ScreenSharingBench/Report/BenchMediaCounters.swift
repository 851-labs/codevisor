public struct BenchMediaCounters: Codable, Sendable, Equatable {
  public var framesSent: Int
  public var framesLost: Int
  public var tilesSkipped: Int
  public var droppedBeforeEncode: Int
  public var admissionDeferrals: Int
  public var nacksSent: Int
  public var packetsRetransmitted: Int
  public var parityPackets: Int
  public var fecRepairs: Int
  public var nackRepairs: Int
  public var ltrRefreshes: Int
  public var keyframes: Int
  public var capacityKbps: Int?
  public var roundTripMs: Double?
  public var requestedRefreshes: Int?
  public var requestedKeyframes: Int?
  public var stalledTiles: Int?
  public var encodedFrames: Int?
  public var encodedBytes: Int?
  public var encodedKeyFrameBytes: Int?
  public var encoderSwitches: Int?
  public var ltrRefreshKeyframes: Int?

  public init(
    framesSent: Int, framesLost: Int, tilesSkipped: Int, droppedBeforeEncode: Int, admissionDeferrals: Int,
    nacksSent: Int, packetsRetransmitted: Int, parityPackets: Int, fecRepairs: Int, nackRepairs: Int,
    ltrRefreshes: Int, keyframes: Int, capacityKbps: Int?, roundTripMs: Double?, requestedRefreshes: Int? = nil,
    requestedKeyframes: Int? = nil, stalledTiles: Int? = nil, encodedFrames: Int? = nil, encodedBytes: Int? = nil,
    encodedKeyFrameBytes: Int? = nil, encoderSwitches: Int? = nil, ltrRefreshKeyframes: Int? = nil
  ) {
    self.framesSent = framesSent
    self.framesLost = framesLost
    self.tilesSkipped = tilesSkipped
    self.droppedBeforeEncode = droppedBeforeEncode
    self.admissionDeferrals = admissionDeferrals
    self.nacksSent = nacksSent
    self.packetsRetransmitted = packetsRetransmitted
    self.parityPackets = parityPackets
    self.fecRepairs = fecRepairs
    self.nackRepairs = nackRepairs
    self.ltrRefreshes = ltrRefreshes
    self.keyframes = keyframes
    self.capacityKbps = capacityKbps
    self.roundTripMs = roundTripMs
    self.requestedRefreshes = requestedRefreshes
    self.requestedKeyframes = requestedKeyframes
    self.stalledTiles = stalledTiles
    self.encodedFrames = encodedFrames
    self.encodedBytes = encodedBytes
    self.encodedKeyFrameBytes = encodedKeyFrameBytes
    self.encoderSwitches = encoderSwitches
    self.ltrRefreshKeyframes = ltrRefreshKeyframes
  }
}
