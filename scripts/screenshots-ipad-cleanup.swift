import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGB {
  var red: Double
  var green: Double
  var blue: Double

  func distance(to other: RGB) -> Double {
    max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
  }

}

struct Bitmap {
  let width: Int
  let height: Int
  let colorSpace: CGColorSpace
  var bytes: [UInt8]

  init(contentsOf url: URL) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CocoaError(.fileReadCorruptFile) }
    width = image.width
    height = image.height
    colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    bytes = [UInt8](repeating: 0, count: width * height * 4)
    let space = colorSpace
    bytes.withUnsafeMutableBytes { buffer in
      Self.context(buffer.baseAddress, width: image.width, height: image.height, space: space)?
        .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
  }

  subscript(x: Int, y: Int) -> RGB {
    get {
      let index = (y * width + x) * 4
      return RGB(red: Double(bytes[index]), green: Double(bytes[index + 1]), blue: Double(bytes[index + 2]))
    }
    set {
      let index = (y * width + x) * 4
      bytes[index] = UInt8(max(0, min(255, newValue.red.rounded())))
      bytes[index + 1] = UInt8(max(0, min(255, newValue.green.rounded())))
      bytes[index + 2] = UInt8(max(0, min(255, newValue.blue.rounded())))
      bytes[index + 3] = 255
    }
  }

  func write(to url: URL) throws {
    var copy = bytes
    let image = copy.withUnsafeMutableBytes { buffer in
      Self.context(buffer.baseAddress, width: width, height: height, space: colorSpace)?.makeImage()
    }
    guard let image,
      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
  }

  private static func context(
    _ data: UnsafeMutableRawPointer?, width: Int, height: Int, space: CGColorSpace
  ) -> CGContext? {
    CGContext(
      data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }
}

enum ResizeGrabber {
  private static let area = 60
  private static let clearOfComposerX = 34
  private static let clearOfComposerY = 48
  private static let strongDifference = 20.0
  private static let margin = 3

  static func erase(in bitmap: inout Bitmap) {
    let background = bitmap[bitmap.width - 150, bitmap.height - 12]
    let strong = points(in: bitmap).filter { bitmap[$0.x, $0.y].distance(to: background) > strongDifference }
    for point in strong {
      for y in (point.y - margin)...(point.y + margin) {
        for x in (point.x - margin)...(point.x + margin) where isGrabberArea(x: x, y: y, in: bitmap) {
          bitmap[x, y] = background
        }
      }
    }
  }

  private static func points(in bitmap: Bitmap) -> [(x: Int, y: Int)] {
    ((bitmap.height - area)..<bitmap.height).flatMap { y in
      ((bitmap.width - area)..<bitmap.width).compactMap { x in
        isGrabberArea(x: x, y: y, in: bitmap) ? (x, y) : nil
      }
    }
  }

  private static func isGrabberArea(x: Int, y: Int, in bitmap: Bitmap) -> Bool {
    guard x < bitmap.width, y < bitmap.height, x >= bitmap.width - area, y >= bitmap.height - area else {
      return false
    }
    return x >= bitmap.width - clearOfComposerX || y >= bitmap.height - clearOfComposerY
  }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: screenshots-ipad-cleanup.swift <screenshot.png>\n".utf8))
  exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
var screenshot = try Bitmap(contentsOf: url)
ResizeGrabber.erase(in: &screenshot)
try screenshot.write(to: url)
print("\(url.lastPathComponent): erased the resize grabber")
