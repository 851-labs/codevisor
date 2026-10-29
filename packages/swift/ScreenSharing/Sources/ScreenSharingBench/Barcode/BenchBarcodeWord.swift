struct BenchBarcodeWord: Equatable {
  private static let checksumBits = 8
  private static let polynomial: UInt8 = 0x1D
  private static let initialChecksum: UInt8 = 0xFF

  let bits: UInt32

  init(bits: UInt32) {
    self.bits = bits
  }

  init(version: Int) {
    precondition(BenchBarcode.versions.contains(version), "Barcode versions are 24-bit")
    let payload = UInt32(version)
    bits = payload << Self.checksumBits | UInt32(Self.checksum(of: payload))
  }

  var version: Int? {
    let payload = bits >> Self.checksumBits
    guard UInt8(truncatingIfNeeded: bits) == Self.checksum(of: payload) else { return nil }

    return Int(payload)
  }

  func isLight(block index: Int) -> Bool {
    bits & Self.mask(block: index) != 0
  }

  static func mask(block index: Int) -> UInt32 {
    1 << UInt32(BenchBarcode.blockCount - 1 - index)
  }

  private static func checksum(of payload: UInt32) -> UInt8 {
    var checksum = initialChecksum
    for shift in [16, 8, 0] {
      checksum ^= UInt8(truncatingIfNeeded: payload >> shift)
      for _ in 0..<8 { checksum = step(checksum) }
    }
    return checksum
  }

  private static func step(_ checksum: UInt8) -> UInt8 {
    guard checksum & 0x80 != 0 else { return checksum << 1 }

    return checksum << 1 ^ polynomial
  }
}
