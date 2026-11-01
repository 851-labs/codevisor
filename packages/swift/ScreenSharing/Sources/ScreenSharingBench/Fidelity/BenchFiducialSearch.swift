struct BenchFiducialSearch {
  let image: BenchLumaImage
  let template: BenchFiducialTemplate
  let origins: [BenchPixelOffset]

  var singles: [BenchFiducialSearch] {
    origins.map { BenchFiducialSearch(image: image, template: template, origins: [$0]) }
  }

  func downsampled(by factor: Int) -> BenchFiducialSearch {
    BenchFiducialSearch(
      image: image.downsampled(by: factor), template: template.downsampled(by: factor),
      origins: origins.map { BenchPixelOffset(dx: $0.dx / factor, dy: $0.dy / factor) })
  }

  func best(of candidates: [BenchPixelOffset]) -> BenchPixelOffset {
    var best = candidates[0]
    var bestScore = Float.infinity
    for candidate in candidates {
      guard let score = score(at: candidate), score < bestScore else { continue }

      best = candidate
      bestScore = score
    }
    return best
  }

  func meanError(at offset: BenchPixelOffset) -> Float {
    (score(at: offset) ?? .infinity) / Float(origins.count * template.size * template.size)
  }

  private func score(at offset: BenchPixelOffset) -> Float? {
    var total: Float = 0
    for origin in origins {
      let placed = origin + offset
      guard fits(placed) else { return nil }

      total += image.absoluteDifference(of: template, at: placed)
    }
    return total
  }

  private func fits(_ origin: BenchPixelOffset) -> Bool {
    origin.dx >= 0 && origin.dy >= 0 && origin.dx + template.size <= image.width
      && origin.dy + template.size <= image.height
  }
}
