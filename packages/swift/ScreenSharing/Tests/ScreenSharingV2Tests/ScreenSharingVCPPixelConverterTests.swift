import CoreVideo
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

struct ScreenSharingVCPPixelConverterTests {
  private static let colours: [(red: UInt8, green: UInt8, blue: UInt8)] = [
    (255, 255, 255), (0, 0, 0), (128, 128, 128), (51, 51, 51), (255, 0, 0), (0, 255, 0), (0, 0, 255), (89, 25, 128),
  ]

  @Test func convertsBGRAToFullRangeBT709FourFourFourExactly() throws {
    let converter = try ScreenSharingVCPPixelConverter(width: 64, height: 8 * Self.colours.count)

    let converted = try converter.convert(try Self.bands(), capture: 1)

    #expect(CVPixelBufferGetPixelFormatType(converted) == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
    #expect(
      CVBufferCopyAttachment(converted, kCVImageBufferTransferFunctionKey, nil) as? String
        == kCVImageBufferTransferFunction_sRGB as String)
    let measured = Self.colours.indices.map { Self.sample(converted, row: $0 * 8 + 4) }
    let expected = Self.colours.map(Self.bt709FullRange)
    #expect(measured.map(\.0) == expected.map(\.0))
    #expect(zip(measured, expected).allSatisfy { abs($0.1 - $1.1) <= 1 && abs($0.2 - $1.2) <= 1 }, "\(measured)")
  }

  @Test func scalesACaptureOfAnotherSizeInsteadOfReadingPastIt() throws {
    let converter = try ScreenSharingVCPPixelConverter(width: 128, height: 16 * Self.colours.count)

    let converted = try converter.convert(try Self.bands(), capture: 1)

    #expect(CVPixelBufferGetWidth(converted) == 128)
    #expect(CVPixelBufferGetHeight(converted) == 16 * Self.colours.count)
    #expect(Self.sample(converted, row: 8).0 >= 250)
  }

  private static func bt709FullRange(_ colour: (red: UInt8, green: UInt8, blue: UInt8)) -> (Int, Int, Int) {
    let (red, green, blue) = (Double(colour.red), Double(colour.green), Double(colour.blue))
    let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    let clamp = { (value: Double) in min(255, max(0, Int(value.rounded()))) }
    return (clamp(luma), clamp(128 + (blue - luma) / 1.8556), clamp(128 + (red - luma) / 1.5748))
  }

  private static func sample(_ buffer: CVPixelBuffer, row: Int) -> (Int, Int, Int) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let lumaRow = row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let chromaRow = row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    return (Int(luma[lumaRow + 10]), Int(chroma[chromaRow + 20]), Int(chroma[chromaRow + 21]))
  }

  private static func bands() throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
    CVPixelBufferCreate(nil, 64, 8 * colours.count, kCVPixelFormatType_32BGRA, attributes, &created)
    let buffer = try #require(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<(8 * colours.count) {
      let colour = colours[row / 8]
      for column in 0..<64 {
        let pixel = base + row * stride + column * 4
        (pixel[0], pixel[1], pixel[2], pixel[3]) = (colour.blue, colour.green, colour.red, 255)
      }
    }
    return buffer
  }
}
