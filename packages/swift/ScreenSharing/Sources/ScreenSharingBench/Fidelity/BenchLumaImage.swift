public struct BenchLumaImage: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let luma: [Float]

  public init(width: Int, height: Int, luma: [Float]) {
    precondition(luma.count == width * height, "A luma image needs one value a pixel")
    self.width = width
    self.height = height
    self.luma = luma
  }

  public init(_ planes: BenchYCbCrPlanes) {
    self.init(width: planes.width, height: planes.height, luma: planes.luma)
  }

  func downsampled(by factor: Int) -> BenchLumaImage {
    let width = self.width / factor
    let height = self.height / factor
    var output = [Float](repeating: 0, count: width * height)
    let area = Float(factor * factor)
    for y in 0..<height {
      for x in 0..<width {
        output[y * width + x] = blockSum(x: x * factor, y: y * factor, size: factor) / area
      }
    }
    return BenchLumaImage(width: width, height: height, luma: output)
  }

  func absoluteDifference(of template: BenchFiducialTemplate, at origin: BenchPixelOffset) -> Float {
    var total: Float = 0
    for row in 0..<template.size {
      let imageRow = (origin.dy + row) * width + origin.dx
      let templateRow = row * template.size
      for column in 0..<template.size {
        total += abs(luma[imageRow + column] - template.luma[templateRow + column])
      }
    }
    return total
  }

  private func blockSum(x: Int, y: Int, size: Int) -> Float {
    var total: Float = 0
    for row in y..<y + size {
      for column in x..<x + size { total += luma[row * width + column] }
    }
    return total
  }
}
