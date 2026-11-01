public enum BenchCardMasks {
  public static let textLumaThreshold: Float = 16
  public static let inkChannelThreshold = 32
  private static let tileEdgeInset = 2

  public static func text(_ reference: BenchYCbCrPlanes, excluding nonText: [BenchPixelRect]) -> [Bool] {
    let background = modeLuma(reference.luma)
    let ink = reference.luma.map { abs($0 - background) > textLumaThreshold }
    let dilated = dilate(ink, width: reference.width, height: reference.height)
    return excluded(dilated, nonText, width: reference.width)
  }

  public static func colouredText(_ reference: BenchRGBImage, tiles: [BenchPixelRect]) -> [Bool] {
    var mask = [Bool](repeating: false, count: reference.width * reference.height)
    for tile in tiles.map({ $0.insetBy(tileEdgeInset) }) {
      let paper = modeColor(reference, in: tile)
      for y in tile.y..<tile.maxY {
        for x in tile.x..<tile.maxX where reference.pixel(x: x, y: y).largestChannelDifference(from: paper) > inkChannelThreshold {
          mask[y * reference.width + x] = true
        }
      }
    }
    return mask
  }

  private static func modeLuma(_ luma: [Float]) -> Float {
    var counts = [Int](repeating: 0, count: 256)
    for value in luma { counts[min(255, max(0, Int(value.rounded())))] += 1 }
    return Float(counts.indices.max { counts[$0] < counts[$1] } ?? 0)
  }

  private static func modeColor(_ image: BenchRGBImage, in rect: BenchPixelRect) -> BenchRGB {
    var counts: [BenchRGB: Int] = [:]
    for y in rect.y..<rect.maxY {
      for x in rect.x..<rect.maxX { counts[image.pixel(x: x, y: y), default: 0] += 1 }
    }
    return counts.max { $0.value < $1.value }?.key ?? BenchRGB(red: 0, green: 0, blue: 0)
  }

  private static func dilate(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
    var output = mask
    for y in 0..<height {
      for x in 0..<width where mask[y * width + x] {
        for row in max(0, y - 1)...min(height - 1, y + 1) {
          for column in max(0, x - 1)...min(width - 1, x + 1) { output[row * width + column] = true }
        }
      }
    }
    return output
  }

  private static func excluded(_ mask: [Bool], _ rects: [BenchPixelRect], width: Int) -> [Bool] {
    var output = mask
    for rect in rects {
      for y in rect.y..<rect.maxY {
        for x in rect.x..<rect.maxX { output[y * width + x] = false }
      }
    }
    return output
  }
}
