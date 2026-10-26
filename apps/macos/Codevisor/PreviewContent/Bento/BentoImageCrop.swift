#if DEBUG
  import CoreGraphics
  import Foundation
  import ImageIO
  import UniformTypeIdentifiers

  struct BentoImageCrop {
    private let image: CGImage
    private let alpha: [UInt8]

    private static let insetPastRoundedCorners = 24
    private static let minimumBoxHeight = 40

    init(image: CGImage) throws {
      self.image = image
      alpha = Self.alphaChannel(of: image)
    }

    func cropped(toSection section: Int?) throws -> CGImage {
      let bounds = try section.map(sectionBounds) ?? fullBounds
      return image.cropping(to: visibleBounds(in: bounds)) ?? image
    }

    static func writePNG(_ image: CGImage, to file: URL) throws {
      guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
      else { throw CocoaError(.fileWriteUnknown) }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private var fullBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    private func sectionBounds(_ section: Int) throws -> CGRect {
      let column = rightmostVisibleColumn() - Self.insetPastRoundedCorners
      guard column >= 0 else { throw BentoCaptureError.sectionNotFound(section) }
      let boxes = boxRuns(atColumn: column)
      guard boxes.indices.contains(section) else { throw BentoCaptureError.sectionNotFound(section) }
      let top = section == 0 ? 0 : boxes[section - 1].upperBound
      return CGRect(x: 0, y: top, width: image.width, height: boxes[section].upperBound - top)
    }

    private func boxRuns(atColumn column: Int) -> [Range<Int>] {
      var runs: [Range<Int>] = []
      var start: Int?
      for y in 0...image.height {
        let visible = y < image.height && isVisible(x: column, y: y)
        if visible, start == nil { start = y }
        if !visible, let first = start {
          if y - first >= Self.minimumBoxHeight { runs.append(first..<y) }
          start = nil
        }
      }
      return runs
    }

    private func rightmostVisibleColumn() -> Int {
      (0..<image.width).reversed().first { x in (0..<image.height).contains { isVisible(x: x, y: $0) } } ?? 0
    }

    private func visibleBounds(in rect: CGRect) -> CGRect {
      let xs = Int(rect.minX)..<Int(rect.maxX)
      let ys = Int(rect.minY)..<Int(rect.maxY)
      let rows = ys.filter { y in xs.contains { isVisible(x: $0, y: y) } }
      let columns = xs.filter { x in rows.contains { isVisible(x: x, y: $0) } }
      guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last
      else { return rect }
      return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private func isVisible(x: Int, y: Int) -> Bool {
      alpha[y * image.width + x] > 0
    }

    private static func alphaChannel(of image: CGImage) -> [UInt8] {
      var pixels = [UInt8](repeating: 0, count: image.width * image.height)
      pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      }
      return pixels
    }
  }
#endif
