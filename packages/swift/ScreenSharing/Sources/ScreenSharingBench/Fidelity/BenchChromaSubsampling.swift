public enum BenchChromaSubsampling {
  private static let block = 2

  public static func roundTrip420(_ planes: BenchYCbCrPlanes) -> BenchYCbCrPlanes {
    var result = planes
    result.blue = roundTrip(planes.blue, width: planes.width, height: planes.height)
    result.red = roundTrip(planes.red, width: planes.width, height: planes.height)
    return result
  }

  private static func roundTrip(_ plane: [Float], width: Int, height: Int) -> [Float] {
    var output = plane
    for top in stride(from: 0, to: height, by: block) {
      for left in stride(from: 0, to: width, by: block) {
        let indices = blockIndices(left: left, top: top, width: width, height: height)
        let mean = indices.reduce(Float(0)) { $0 + plane[$1] } / Float(indices.count)
        for index in indices { output[index] = mean }
      }
    }
    return output
  }

  private static func blockIndices(left: Int, top: Int, width: Int, height: Int) -> [Int] {
    (top..<min(top + block, height)).flatMap { y in (left..<min(left + block, width)).map { y * width + $0 } }
  }
}
