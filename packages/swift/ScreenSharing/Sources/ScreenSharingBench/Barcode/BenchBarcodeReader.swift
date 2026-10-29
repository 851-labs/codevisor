struct BenchBarcodeReader {
  static let minimumBlockContrast = 64

  let plane: BenchLumaPlane
  let layout: BenchBarcodeLayout

  func reading() -> BenchBarcodeReading {
    var bits: UInt32 = 0
    for block in 0..<BenchBarcode.blockCount {
      let contrast = dataLuma(block: block) - complementLuma(block: block)
      guard abs(contrast) >= Self.minimumBlockContrast else { return .ambiguousBlock(block) }

      if contrast > 0 { bits |= BenchBarcodeWord.mask(block: block) }
    }
    guard let version = BenchBarcodeWord(bits: bits).version else { return .checksumMismatch }

    return .version(version)
  }

  private func dataLuma(block: Int) -> Int {
    blockLuma(block: block, top: layout.y)
  }

  private func complementLuma(block: Int) -> Int {
    blockLuma(block: block, top: layout.y + layout.blockSize)
  }

  private func blockLuma(block: Int, top: Int) -> Int {
    plane.meanLuma(columns: samples(from: layout.x + block * layout.blockSize), rows: samples(from: top))
  }

  private func samples(from start: Int) -> (Int, Int) {
    (start + layout.blockSize * 3 / 8, start + layout.blockSize * 5 / 8)
  }
}
