import CoreVideo
import Testing

@testable import CodevisorBench

struct EncodeLabReferencePictureTests {
  @Test(arguments: [
    (true, [255, 128, 128], [0, 128, 128], [40, 128, 128], [54, 99, 255]),
    (false, [235, 128, 128], [16, 128, 128], [50, 128, 128], [63, 102, 240]),
  ])
  func convertsBGRAToBT709InEitherRange(fullRange: Bool, white: [Int], black: [Int], grey: [Int], red: [Int]) throws {
    let colours: [(UInt8, UInt8, UInt8)] = [(255, 255, 255), (0, 0, 0), (40, 40, 40), (255, 0, 0)]
    let picture = EncodeLabReferencePicture.make(from: try Self.pixels(colours), fullRange: fullRange)

    let converted = colours.indices.map { [picture.luma[$0], picture.blue[$0], picture.red[$0]].map(Int.init) }

    #expect(converted == [white, black, grey, red])
  }

  private static func pixels(_ colours: [(UInt8, UInt8, UInt8)]) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, colours.count, 1, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    for (index, (red, green, blue)) in colours.enumerated() {
      (base + index * 4).update(from: [blue, green, red, 255], count: 4)
    }
    return pixels
  }
}
