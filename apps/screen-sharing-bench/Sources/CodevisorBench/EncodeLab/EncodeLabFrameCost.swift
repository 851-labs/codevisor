struct EncodeLabFrameCost: Codable, Sendable {
  let kilobytes: Double
  let encodeMs: Double
  let keyframe: Bool
  let kind: EncodeLabRefresh?

  init?(outputs: [EncodeLabTileOutput], event: EncodeLabFrameEvent, only tile: Int? = nil) {
    let chosen = outputs.filter { tile == nil || $0.tile == tile }
    guard let latest = chosen.map(\.outputNs).max() else { return nil }

    kilobytes = Double(chosen.map(\.bytes).reduce(0, +)) / 1000
    encodeMs = Double(latest - event.submittedNs) / 1e6
    keyframe = chosen.contains(where: \.keyframe)
    kind = event.refresh
  }
}
