public struct BenchTextFidelityAnalysis: Sendable {
  public let fidelity: BenchTextFidelity
  public let notOneToOneReason: String?
  public let reference420PsnrCbcr: Double?
  public let textFrames: Int
  public let chromaFrames: Int

  public init?(_ captures: [BenchCardCapture], geometry: BenchCardGeometry) throws {
    guard !captures.isEmpty else { return nil }

    textFrames = captures.count { $0.kind == .text }
    chromaFrames = captures.count { $0.kind == .chroma }
    switch try Self.totals(of: captures, geometry: geometry) {
    case .success(let totals):
      fidelity = totals.fidelity
      notOneToOneReason = nil
      reference420PsnrCbcr = totals.chroma420.psnr.map { min($0, BenchTextFidelity.identicalPSNR) }
    case .failure(let failure):
      fidelity = .notOneToOne
      notOneToOneReason = failure.reason
      reference420PsnrCbcr = nil
    }
  }

  private static func totals(
    of captures: [BenchCardCapture], geometry: BenchCardGeometry
  ) throws -> Result<BenchFidelityTotals, NotOneToOne> {
    var totals = BenchFidelityTotals()
    for capture in captures {
      switch registered(capture, geometry: geometry) {
      case .failure(let failure): return .failure(failure)
      case .success(let crops): try add(crops, kind: capture.kind, geometry: geometry, to: &totals)
      }
    }
    return .success(totals)
  }

  private struct Crops {
    let reference: BenchRGBImage
    let shown: BenchRGBImage
  }

  private struct NotOneToOne: Error {
    let reason: String
  }

  private static func registered(
    _ capture: BenchCardCapture, geometry: BenchCardGeometry
  ) -> Result<Crops, NotOneToOne> {
    let reference = crop(capture.reference, geometry: geometry, side: "host")
    let shown = crop(capture.shown, geometry: geometry, side: "viewer")
    switch (reference, shown) {
    case (.success(let reference), .success(let shown)): return .success(Crops(reference: reference, shown: shown))
    case (.failure(let failure), _), (_, .failure(let failure)):
      return .failure(NotOneToOne(reason: "version \(capture.version): \(failure.reason)"))
    }
  }

  private static func crop(
    _ image: BenchRGBImage, geometry: BenchCardGeometry, side: String
  ) -> Result<BenchRGBImage, NotOneToOne> {
    switch BenchRegistration.register(BenchLumaImage(BenchYCbCrPlanes(image)), geometry: geometry) {
    case .registered(let offset): .success(image.cropped(to: geometry.canvas.offsetBy(offset)))
    case .notOneToOne(let reason): .failure(NotOneToOne(reason: "\(side): \(reason)"))
    }
  }

  private static func add(
    _ crops: Crops, kind: BenchCardCapture.Kind, geometry: BenchCardGeometry, to totals: inout BenchFidelityTotals
  ) throws {
    switch kind {
    case .text:
      let reference = BenchYCbCrPlanes(crops.reference)
      let mask = BenchCardMasks.text(reference, excluding: geometry.nonText)
      try totals.addText(reference: reference, shown: BenchYCbCrPlanes(crops.shown), mask: mask)
    case .chroma:
      let mask = BenchCardMasks.colouredText(crops.reference, tiles: geometry.chromaTiles)
      totals.addChroma(reference: crops.reference, shown: crops.shown, mask: mask)
    }
  }
}
