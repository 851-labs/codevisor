#if DEBUG
  import CoreGraphics

  struct BentoSheetCrop {
    private let width: Int
    private let height: Int
    private let colorSpace: CGColorSpace
    private var pixels: [UInt8]

    private static let bytesPerPixel = 4
    private static let opaque: UInt8 = 255

    init(image: CGImage) {
      width = image.width
      height = image.height
      colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
      pixels = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
      pixels.withUnsafeMutableBytes { buffer in
        Self.context(buffer.baseAddress, width: width, height: height, colorSpace: colorSpace)?
          .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      }
    }

    func panelWithoutScrim() -> CGImage? {
      guard let panel = opaqueBounds() else { return nil }
      let scrimAlpha = alpha(x: panel.minX, y: panel.minY)
      var cropped = [UInt8]()
      for y in panel.minY...panel.maxY {
        for x in panel.minX...panel.maxX {
          cropped += Self.removingScrim(pixel(x: x, y: y), scrimAlpha: scrimAlpha)
        }
      }
      let size = (width: panel.maxX - panel.minX + 1, height: panel.maxY - panel.minY + 1)
      return cropped.withUnsafeMutableBytes {
        Self.context($0.baseAddress, width: size.width, height: size.height, colorSpace: colorSpace)?.makeImage()
      }
    }

    private func opaqueBounds() -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
      let rows = (0..<height).filter { y in (0..<width).contains { alpha(x: $0, y: y) == Self.opaque } }
      let columns = (0..<width).filter { x in rows.contains { alpha(x: x, y: $0) == Self.opaque } }
      guard let minY = rows.first, let maxY = rows.last, let minX = columns.first, let maxX = columns.last
      else { return nil }
      return (minX, minY, maxX, maxY)
    }

    private func alpha(x: Int, y: Int) -> UInt8 { pixels[(y * width + x) * Self.bytesPerPixel + 3] }

    private func pixel(x: Int, y: Int) -> ArraySlice<UInt8> {
      let start = (y * width + x) * Self.bytesPerPixel
      return pixels[start..<start + Self.bytesPerPixel]
    }

    private static func removingScrim(_ pixel: ArraySlice<UInt8>, scrimAlpha: UInt8) -> [UInt8] {
      guard scrimAlpha < opaque else { return Array(pixel) }
      let alpha = Double(pixel[pixel.startIndex + 3])
      let remaining = max(0, alpha - Double(scrimAlpha)) / (Double(opaque) - Double(scrimAlpha))
      let scale = alpha == 0 ? 0 : remaining * Double(opaque) / alpha
      return pixel.prefix(3).map { UInt8(min(Double(opaque), Double($0) * scale)) } + [
        UInt8(remaining * Double(opaque))
      ]
    }

    private static func context(
      _ data: UnsafeMutableRawPointer?, width: Int, height: Int, colorSpace: CGColorSpace
    ) -> CGContext? {
      CGContext(
        data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * bytesPerPixel,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
  }
#endif
