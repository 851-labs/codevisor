public enum BenchRegistration {
  public enum Outcome: Sendable, Equatable {
    case registered(BenchPixelOffset)
    case notOneToOne(String)
  }

  private static let coarseFactor = 4
  private static let directSearchLimit = 33 * 33
  private static let checkRadius = 2
  private static let maximumMeanError: Float = 48

  public static func register(_ image: BenchLumaImage, geometry: BenchCardGeometry) -> Outcome {
    guard let range = offsets(fitting: geometry, in: image) else {
      return .notOneToOne(
        "the \(image.width)x\(image.height) capture is smaller than the \(geometry.canvasWidth)x"
          + "\(geometry.canvasHeight) card")
    }

    let template = BenchFiducialTemplate(size: geometry.fiducialSize)
    let search = BenchFiducialSearch(image: image, template: template, origins: geometry.fiducialOrigins)
    let offset = range.count <= directSearchLimit ? search.best(of: range.offsets) : coarseToFine(search, range)
    return check(search, at: offset, range: range)
  }

  private static func offsets(fitting geometry: BenchCardGeometry, in image: BenchLumaImage) -> BenchOffsetRange? {
    BenchOffsetRange(
      dx: (0, image.width - geometry.canvasWidth), dy: (0, image.height - geometry.canvasHeight))
  }

  private static func coarseToFine(_ search: BenchFiducialSearch, _ range: BenchOffsetRange) -> BenchPixelOffset {
    let coarse = search.downsampled(by: coarseFactor).best(of: range.scaled(down: coarseFactor).offsets)
    let center = BenchPixelOffset(dx: coarse.dx * coarseFactor, dy: coarse.dy * coarseFactor)
    return search.best(of: range.around(center, radius: coarseFactor))
  }

  private static func check(
    _ search: BenchFiducialSearch, at offset: BenchPixelOffset, range: BenchOffsetRange
  ) -> Outcome {
    for (index, single) in search.singles.enumerated() {
      let own = single.best(of: range.around(offset, radius: checkRadius))
      guard own == offset else {
        return .notOneToOne("fiducial \(index + 1) registers at \(describe(own)), the others at \(describe(offset))")
      }

      let error = single.meanError(at: offset)
      guard error <= maximumMeanError else {
        return .notOneToOne("fiducial \(index + 1) doesn't match at 1:1 (mean error \(Int(error.rounded())))")
      }
    }
    return .registered(offset)
  }

  private static func describe(_ offset: BenchPixelOffset) -> String {
    "(\(offset.dx), \(offset.dy))"
  }
}
