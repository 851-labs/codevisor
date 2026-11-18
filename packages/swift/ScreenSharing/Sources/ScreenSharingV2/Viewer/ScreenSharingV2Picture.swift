import CoreVideo

struct ScreenSharingV2Picture {
  struct Composite: @unchecked Sendable {
    let sequence: UInt64
    let snapshot: ScreenSharingV2TileCanvas.Snapshot
    let group: ScreenSharingV2UpdateAssembly.Group?
  }

  struct Placement: Sendable {
    let composite: Composite?
    let isLate: Bool
  }

  var gate = ScreenSharingV2RecoveryGate()
  private var assembly = ScreenSharingV2UpdateAssembly()
  private var canvas: ScreenSharingV2TileCanvas?
  private var encoder: ScreenSharingV2EncoderGeneration?
  private var nextComposite: UInt64 = 0

  mutating func follows(_ meta: ScreenSharingV2FrameMeta) -> Bool {
    guard !shows(meta) else { return true }
    guard !isReplaced(meta.encoder) else { return false }

    if meta.encoder != encoder { gate.restart() }
    encoder = meta.encoder
    canvas = ScreenSharingV2TileCanvas(layout: meta.layout)
    assembly.clear()
    return true
  }

  mutating func received(_ update: ScreenSharingTileUpdate, tile: Int) {
    assembly.received(update, tile: tile)
  }

  mutating func skipped(tile: Int) -> Composite? {
    assembly.skipped(tile: tile)
    return compose()
  }

  mutating func resolved(
    _ outcome: ScreenSharingV2UpdateAssembly.Outcome, of meta: ScreenSharingV2FrameMeta, tile: Int
  ) -> Placement? {
    guard shows(meta) else { return nil }

    let isCurrent = assembly.resolve(update: meta.update.id, tile: tile, outcome)
    guard case .decoded(_, let image) = outcome, !isCurrent else {
      return Placement(composite: compose(), isLate: false)
    }

    canvas?.place(image, tile: tile)
    return Placement(composite: compose(presentingLate: true), isLate: true)
  }

  private func shows(_ meta: ScreenSharingV2FrameMeta) -> Bool {
    canvas?.layout == meta.layout && encoder == meta.encoder
  }

  private func isReplaced(_ sender: ScreenSharingV2EncoderGeneration?) -> Bool {
    guard let sender, let encoder else { return false }

    return encoder.replaces(sender)
  }

  private mutating func compose(presentingLate: Bool = false) -> Composite? {
    let ready = assembly.ready()
    for released in ready {
      for (tile, image) in released.images { canvas?.place(image, tile: tile) }
    }
    let group = ready.last { !$0.decoded.isEmpty }
    guard group != nil || presentingLate, let snapshot = canvas?.snapshot else { return nil }

    nextComposite += 1
    return Composite(sequence: nextComposite, snapshot: snapshot, group: group)
  }
}
