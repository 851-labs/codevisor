import CoreVideo
import MetalKit
import Testing

@testable import ScreenSharing

@MainActor
struct ScreenSharingTiledRenderTests {
  private static let width = 64
  private static let height = 256
  private static let tileRows = [0..<64, 64..<128, 128..<192, 192..<256]
  private static let size = CGSize(width: width, height: height)

  @Test func aTiledFrameIsTheSizeOfTheWholePicture() throws {
    let frame = try #require(try Self.tiledFrame())

    #expect(frame.size == Self.size)
  }

  @Test func tilesDrawnAtHalfSizeMatchTheWholePictureExactly() throws {
    let gpu = try TiledRenderFixture()

    let whole = try gpu.render(ScreenSharingVideoFrame(pixelBuffer: try Self.picture(), timestampNs: 1), 32, 128)
    let tiled = try gpu.render(try #require(try Self.tiledFrame()), 32, 128)

    #expect(tiled == whole)
  }

  @Test(arguments: [
    (1280, 720), (1920, 1080), (853, 480), (640, 360), (457, 257),
  ])
  func atEveryScaleATiledPictureIsWithinTwoLevelsOfTheComposedOneEvenAtTheTileEdges(width: Int, height: Int) throws {
    let gpu = try TiledRenderFixture()
    for format in VideoContent.formats {
      for content in [VideoContent.noise, .text] {
        let whole = ScreenSharingVideoFrame(
          pixelBuffer: try content.picture(rows: 0..<720, format: format), timestampNs: 1)
        let tiles = try VideoContent.rows.map {
          ScreenSharingVideoTile(pixelBuffer: try content.picture(rows: $0, format: format), rows: $0)
        }
        let tiled = try #require(
          ScreenSharingVideoFrame(tiles: tiles, size: CGSize(width: 1280, height: 720), timestampNs: 1))

        let difference = TiledRenderFixture.largestDifference(
          try gpu.renderAll(whole, width, height), try gpu.renderAll(tiled, width, height))

        #expect(difference <= 2, "\(content) \(format) at \(width)x\(height): \(difference) levels")
      }
    }
  }

  @Test func paddedTilesEnlargedStillEndAtThePicturesLastRowAndColumn() throws {
    let gpu = try TiledRenderFixture()
    let format = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
    let whole = ScreenSharingVideoFrame(
      pixelBuffer: try VideoContent.text.picture(rows: 0..<720, format: format), timestampNs: 1)
    let tiles = try VideoContent.rows.map { rows in
      let padding = rows.upperBound == 720 ? 16 : 0
      let padded = try VideoContent.noise.picture(
        rows: rows.lowerBound..<(rows.upperBound + padding), format: format, width: 1280 + 32)
      return ScreenSharingVideoTile(
        pixelBuffer: padded.replacingTopLeft(with: try VideoContent.text.picture(rows: rows, format: format)),
        rows: rows)
    }
    let tiled = try #require(
      ScreenSharingVideoFrame(tiles: tiles, size: CGSize(width: 1280, height: 720), timestampNs: 1))

    let difference = TiledRenderFixture.largestDifference(
      try gpu.renderAll(whole, 1920, 1080), try gpu.renderAll(tiled, 1920, 1080))

    #expect(difference <= 2, "\(difference) levels")
  }

  @Test func aTileDecodedIntoATallerBufferShowsOnlyItsOwnRows() throws {
    let gpu = try TiledRenderFixture()
    let padded = try Self.tileRows.map { rows in
      ScreenSharingVideoTile(pixelBuffer: try Self.picture(rows: rows.lowerBound..<(rows.upperBound + 16)), rows: rows)
    }

    let whole = try gpu.render(ScreenSharingVideoFrame(pixelBuffer: try Self.picture(), timestampNs: 1), 32, 128)
    let tiled = try gpu.render(
      try #require(ScreenSharingVideoFrame(tiles: padded, size: Self.size, timestampNs: 1)), 32, 128)

    #expect(tiled == whole)
  }

  @Test func aTileDecodedIntoAWiderBufferShowsOnlyThePicturesColumns() throws {
    let gpu = try TiledRenderFixture()
    let wide = try Self.tileRows.map { rows in
      ScreenSharingVideoTile(pixelBuffer: try Self.picture(rows: rows, width: Self.width + 32), rows: rows)
    }

    let whole = try gpu.render(ScreenSharingVideoFrame(pixelBuffer: try Self.picture(), timestampNs: 1), 32, 128)
    let tiled = try gpu.render(
      try #require(ScreenSharingVideoFrame(tiles: wide, size: Self.size, timestampNs: 1)), 32, 128)

    #expect(tiled == whole)
  }

  private static func tiledFrame() throws -> ScreenSharingVideoFrame? {
    ScreenSharingVideoFrame(
      tiles: try tileRows.map { ScreenSharingVideoTile(pixelBuffer: try picture(rows: $0), rows: $0) }, size: size,
      timestampNs: 1)
  }

  private static func picture(rows: Range<Int> = 0..<height, width: Int = width) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes =
      [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
      as CFDictionary
    CVPixelBufferCreate(nil, width, rows.count, kCVPixelFormatType_32BGRA, attributes, &created)
    let buffer = try #require(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for (index, row) in rows.enumerated() {
      for column in 0..<width {
        let level = UInt8(column < Self.width ? (row * 37) % 256 : 255)
        let pixel = base + index * stride + column * 4
        (pixel[0], pixel[1], pixel[2], pixel[3]) = (level, level, level, 255)
      }
    }
    return buffer
  }
}

private enum VideoContent {
  case noise
  case text

  static let rows = [0..<192, 192..<384, 384..<576, 576..<720]
  static let formats = [
    kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
  ]

  func picture(rows: Range<Int>, format: OSType, width: Int = 1280) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes =
      [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
      as CFDictionary
    CVPixelBufferCreate(nil, width, rows.count, format, attributes, &created)
    let buffer = try #require(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let half = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
    let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    for (index, row) in rows.enumerated() {
      for column in 0..<width { luma[index * lumaStride + column] = sample(row: row, column: column).0 }
    }
    for index in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
      let row = rows.lowerBound + (half ? index * 2 : index)
      for column in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
        let (_, cb, cr) = sample(row: row, column: half ? column * 2 : column)
        chroma[index * chromaStride + column * 2] = cb
        chroma[index * chromaStride + column * 2 + 1] = cr
      }
    }
    return buffer
  }

  private func sample(row: Int, column: Int) -> (UInt8, UInt8, UInt8) {
    var hash = UInt32(truncatingIfNeeded: row &* 73_856_093 ^ column &* 19_349_663)
    hash ^= hash >> 13
    hash = hash &* 0x5bd1_e995
    hash ^= hash >> 15
    switch self {
    case .noise: return (UInt8(hash & 0xff), UInt8((hash >> 8) & 0xff), UInt8((hash >> 16) & 0xff))
    case .text:
      let line = row % 18
      let ink = line >= 3 && line < 14 && (column / 9 + row / 18) % 7 != 0 && (hash & 3) != 0
      return ink ? (20, 128, 128) : (235, 128, 128)
    }
  }
}

extension CVPixelBuffer {
  fileprivate func replacingTopLeft(with source: CVPixelBuffer) -> CVPixelBuffer {
    CVPixelBufferLockBaseAddress(self, [])
    CVPixelBufferLockBaseAddress(source, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
      CVPixelBufferUnlockBaseAddress(self, [])
    }
    for plane in 0..<CVPixelBufferGetPlaneCount(self) {
      let target = CVPixelBufferGetBaseAddressOfPlane(self, plane)!
      let from = CVPixelBufferGetBaseAddressOfPlane(source, plane)!
      let targetStride = CVPixelBufferGetBytesPerRowOfPlane(self, plane)
      let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
      let bytes = CVPixelBufferGetWidthOfPlane(source, plane) * (plane == 0 ? 1 : 2)
      for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
        memcpy(target + row * targetStride, from + row * sourceStride, bytes)
      }
    }
    return self
  }
}

@MainActor
private struct TiledRenderFixture {
  let device: any MTLDevice
  let encoder: ScreenSharingMetalEncoder

  init() throws {
    device = try #require(MTLCreateSystemDefaultDevice(), "This machine has no Metal device to render with")
    let queue = try #require(device.makeCommandQueue())
    encoder = try ScreenSharingMetalEncoder(
      device: device, commandQueue: queue, pipelines: .init(device: device, shader: ScreenSharingMetalView.shader))
  }

  func render(_ frame: ScreenSharingVideoFrame, _ width: Int, _ height: Int) throws -> [UInt8] {
    let pixels = try renderAll(frame, width, height)
    return (0..<height).map { pixels[($0 * width + width / 2) * 4 + 1] }
  }

  static func largestDifference(_ first: [UInt8], _ second: [UInt8]) -> Int {
    var largest = 0
    for index in first.indices where index % 4 != 3 {
      largest = max(largest, abs(Int(first[index]) - Int(second[index])))
    }
    return largest
  }

  func renderAll(_ frame: ScreenSharingVideoFrame, _ width: Int, _ height: Int) throws -> [UInt8] {
    let textures = try #require(encoder.textures(for: frame))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .managed
    let surface = try #require(device.makeTexture(descriptor: descriptor))
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = surface
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let encoded = try #require(encoder.encode(textures, into: pass, target: surface))
    let blit = try #require(encoded.buffer.makeBlitCommandEncoder())
    blit.synchronize(resource: surface)
    blit.endEncoding()
    encoded.buffer.commit()
    encoded.buffer.waitUntilCompleted()
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    surface.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return pixels
  }
}
