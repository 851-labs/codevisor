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
      let rows = top..<min(top + block, height)
      for left in stride(from: 0, to: width, by: block) {
        let columns = left..<min(left + block, width)
        var sum: Float = 0
        for y in rows { for x in columns { sum += plane[y * width + x] } }
        let mean = sum / Float(rows.count * columns.count)
        for y in rows { for x in columns { output[y * width + x] = mean } }
      }
    }
    return output
  }
}
