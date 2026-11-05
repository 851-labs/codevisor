import CoreVideo
import MetalKit
import Testing

@testable import ScreenSharing

@MainActor
struct ScreenSharingTiledRenderTests {
  private static let width = 64
  private static let height = 256
  private static let tileRows = [0..<64, 64..<128, 128..<192, 192..<256]

  @Test func aTiledFrameIsTheSizeOfTheWholePicture() throws {
    let frame = try #require(try Self.tiledFrame())

    #expect(ScreenSharingMetalEncoder.videoSize(of: frame) == CGSize(width: Self.width, height: Self.height))
  }

  @Test func tilesDrawnAtHalfSizeMatchTheWholePictureExactly() throws {
    let gpu = try TiledRenderFixture()

    let whole = try gpu.render(ScreenSharingVideoFrame(pixelBuffer: try Self.picture(), timestampNs: 1), 32, 128)
    let tiled = try gpu.render(try #require(try Self.tiledFrame()), 32, 128)

    #expect(tiled == whole)
  }

  @Test func atAnyOtherScaleOnlyTheRowsAtATileEdgeDifferAndOnlyByAFewLevels() throws {
    let gpu = try TiledRenderFixture()

    let whole = try gpu.render(ScreenSharingVideoFrame(pixelBuffer: try Self.picture(), timestampNs: 1), 21, 84)
    let tiled = try gpu.render(try #require(try Self.tiledFrame()), 21, 84)

    let differing = (0..<84).filter { whole[$0] != tiled[$0] }
    let edges = Self.tileRows.dropFirst().map { Double($0.lowerBound) * 84 / Double(Self.height) }
    #expect(differing.allSatisfy { row in edges.contains { abs(Double(row) + 0.5 - $0) <= 1.5 } }, "\(differing)")
    #expect(zip(whole, tiled).allSatisfy { abs(Int($0) - Int($1)) <= 4 })
  }

  @Test func aTileDecodedIntoATallerBufferShowsOnlyItsOwnRows() throws {
    let gpu = try TiledRenderFixture()
    let padded = try Self.tileRows.map { rows in
      ScreenSharingVideoTile(pixelBuffer: try Self.picture(rows: rows.lowerBound..<(rows.upperBound + 16)), rows: rows)
    }

    let whole = try gpu.render(ScreenSharingVideoFrame(pixelBuffer: try Self.picture(), timestampNs: 1), 32, 128)
    let tiled = try gpu.render(try #require(ScreenSharingVideoFrame(tiles: padded, timestampNs: 1)), 32, 128)

    #expect(tiled == whole)
  }

  private static func tiledFrame() throws -> ScreenSharingVideoFrame? {
    ScreenSharingVideoFrame(
      tiles: try tileRows.map { ScreenSharingVideoTile(pixelBuffer: try picture(rows: $0), rows: $0) }, timestampNs: 1)
  }

  private static func picture(rows: Range<Int> = 0..<height) throws -> CVPixelBuffer {
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
      let level = UInt8((row * 37) % 256)
      for column in 0..<width {
        let pixel = base + index * stride + column * 4
        (pixel[0], pixel[1], pixel[2], pixel[3]) = (level, level, level, 255)
      }
    }
    return buffer
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
    var pixels = [UInt32](repeating: 0, count: width * height)
    surface.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return (0..<height).map { UInt8((pixels[$0 * width + width / 2] >> 8) & 0xff) }
  }
}
