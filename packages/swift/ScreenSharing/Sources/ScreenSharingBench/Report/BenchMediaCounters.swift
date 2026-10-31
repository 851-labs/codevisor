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

  public init(
    framesSent: Int, framesLost: Int, tilesSkipped: Int, droppedBeforeEncode: Int, admissionDeferrals: Int,
    nacksSent: Int, packetsRetransmitted: Int, parityPackets: Int, fecRepairs: Int, nackRepairs: Int,
    ltrRefreshes: Int, keyframes: Int, capacityKbps: Int?, roundTripMs: Double?
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
  }
}
