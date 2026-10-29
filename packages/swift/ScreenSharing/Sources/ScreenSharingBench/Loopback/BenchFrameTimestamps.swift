public struct BenchFrameTimestamps: Codable, Sendable, Equatable {
  public var sourceNs: Int64
  public var captureCallbackNs: Int64
  public var encodeSubmitNs: Int64
  public var encodeOutputNs: Int64
  public var frameCompleteNs: Int64?
  public var decodeInputNs: Int64
  public var decodeOutputNs: Int64
  public var renderCommitNs: Int64
  public var onGlassNs: Int64?

  public init(
    sourceNs: Int64, captureCallbackNs: Int64, encodeSubmitNs: Int64, encodeOutputNs: Int64, decodeInputNs: Int64,
    decodeOutputNs: Int64, renderCommitNs: Int64, onGlassNs: Int64? = nil, frameCompleteNs: Int64? = nil
  ) {
    self.sourceNs = sourceNs
    self.captureCallbackNs = captureCallbackNs
    self.encodeSubmitNs = encodeSubmitNs
    self.encodeOutputNs = encodeOutputNs
    self.decodeInputNs = decodeInputNs
    self.decodeOutputNs = decodeOutputNs
    self.renderCommitNs = renderCommitNs
    self.onGlassNs = onGlassNs
    self.frameCompleteNs = frameCompleteNs
  }

  public func endNs(at endpoint: BenchEndpoint) -> Int64? {
    switch endpoint {
    case .committed: renderCommitNs
    case .onGlass: onGlassNs
    }
  }

  public func shifted(byNs offset: Int64) -> BenchFrameTimestamps {
    BenchFrameTimestamps(
      sourceNs: sourceNs + offset, captureCallbackNs: captureCallbackNs + offset,
      encodeSubmitNs: encodeSubmitNs + offset, encodeOutputNs: encodeOutputNs + offset,
      decodeInputNs: decodeInputNs + offset, decodeOutputNs: decodeOutputNs + offset,
      renderCommitNs: renderCommitNs + offset, onGlassNs: onGlassNs.map { $0 + offset },
      frameCompleteNs: frameCompleteNs.map { $0 + offset })
  }
}
