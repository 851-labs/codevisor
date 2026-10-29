import CoreVideo
import Metal
import ScreenSharingBench
import Testing

struct BenchBarcodeTests {
  @Test func tenThousandRandomVersionsDecodeAfterANoisy420vRoundTrip() throws {
    let stacked = 100
    let height = stacked * BenchBarcodeLayout.standard.height
    let source = try BenchPixelBuffers.make(width: 512, height: height)
    let video = try BenchPixelBuffers.make(
      width: 512, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let returned = try BenchPixelBuffers.make(width: 512, height: height)
    let transfer = try BenchPixelTransfer()
    var random = SplitMix64(seed: 3590)
    let noise = BenchNoise(amplitude: 12, count: 1 << 20, random: &random)
    let layouts = (0..<stacked).map { BenchBarcodeLayout(y: $0 * BenchBarcodeLayout.standard.height) }

    var misreads: [(version: Int, bgra: BenchBarcodeReading, luma: BenchBarcodeReading)] = []
    for _ in 0..<10_000 / stacked {
      let versions = layouts.map { _ in Int(random.next() % UInt64(BenchBarcode.versions.count)) }
      for (version, layout) in zip(versions, layouts) { try BenchBarcode.draw(version, into: source, layout: layout) }
      try transfer.transfer(source, to: video)
      BenchPixelBuffers.addNoise(to: video, from: noise, random: &random)
      try transfer.transfer(video, to: returned)

      for (version, layout) in zip(versions, layouts) {
        let bgra = try BenchBarcode.read(returned, layout: layout)
        let luma = try BenchBarcode.read(video, layout: layout)
        if bgra != .version(version) || luma != .version(version) { misreads.append((version, bgra, luma)) }
      }
    }
    #expect(misreads.isEmpty, "\(misreads.count) misreads, first: \(String(describing: misreads.first))")
  }

  @Test func tornReadsBetweenNearbyVersionsNeverDecodeToAThirdVersion() throws {
    let pairs = [
      (0x7F_FFFF, 0x80_0000), (0x00_FFFF, 0x01_0000), (0xFF_FFFE, 0xFF_FFFF), (41, 45), (0x12_3456, 0x12_3458),
    ]
    var rejected = 0
    for (older, newer) in pairs {
      for (left, right) in [(older, newer), (newer, older)] {
        for splitBlock in 1..<BenchBarcode.blockCount {
          let reading = try spliced(left: left, right: right, atBlock: splitBlock)
          #expect(
            [.version(left), .version(right), .checksumMismatch].contains(reading), "\(left)|\(right) @\(splitBlock)")
          if reading == .checksumMismatch { rejected += 1 }
        }
      }
    }
    #expect(rejected > 0)
  }

  @Test func aTearBetweenTheDataAndComplementRowsIsAmbiguous() throws {
    let older = try BenchPixelBuffers.make(width: 512, height: 32)
    let newer = try BenchPixelBuffers.make(width: 512, height: 32)
    try BenchBarcode.draw(0b1000_0000, into: older)
    try BenchBarcode.draw(0b1000_0001, into: newer)
    BenchPixelBuffers.copyColumns(0..<512, rows: 0..<16, from: newer, to: older)

    #expect(try BenchBarcode.read(older) == .ambiguousBlock(23))
  }

  @Test func versionsDrawnIntoAMetalTextureDecodeFromItsPixelBuffer() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let buffer = try BenchPixelBuffers.make(width: 400, height: 80)
    let texture = try metalTexture(device: device, backedBy: buffer)
    let layout = BenchBarcodeLayout(x: 40, y: 24, blockSize: 8)
    BenchPixelBuffers.fill(buffer, gray: 90)

    try BenchBarcode.draw(0xC0_FFEE, into: texture, layout: layout)

    #expect(try BenchBarcode.read(buffer, layout: layout) == .version(0xC0_FFEE))
  }

  @Test func drawsAndReadsThatCannotFitAreRejected() throws {
    let buffer = try BenchPixelBuffers.make(width: 511, height: 32)
    let roomy = try BenchPixelBuffers.make(width: 512, height: 32)

    #expect(throws: BenchBarcodeError.layoutOutsideImage) { try BenchBarcode.draw(1, into: buffer) }
    #expect(throws: BenchBarcodeError.layoutOutsideImage) { try BenchBarcode.read(buffer) }
    #expect(throws: BenchBarcodeError.versionOutOfRange(1 << 24)) { try BenchBarcode.draw(1 << 24, into: roomy) }
  }

  private func spliced(left: Int, right: Int, atBlock splitBlock: Int) throws -> BenchBarcodeReading {
    let image = try BenchPixelBuffers.make(width: 512, height: 32)
    let other = try BenchPixelBuffers.make(width: 512, height: 32)
    try BenchBarcode.draw(left, into: image)
    try BenchBarcode.draw(right, into: other)
    BenchPixelBuffers.copyColumns(splitBlock * 16..<512, rows: 0..<32, from: other, to: image)
    return try BenchBarcode.read(image)
  }

  private func metalTexture(device: any MTLDevice, backedBy buffer: CVPixelBuffer) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
      mipmapped: false)
    let surface = try #require(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
    return try #require(device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0))
  }
}
