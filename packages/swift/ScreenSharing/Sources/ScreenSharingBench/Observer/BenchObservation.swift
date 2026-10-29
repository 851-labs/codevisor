public struct BenchObservation: Codable, Sendable, Equatable {
  public enum Unreadable: String, Codable, Sendable {
    case ambiguousBlock = "ambiguous_block"
    case checksumMismatch = "checksum_mismatch"
  }

  public var ptsNs: Int64
  public var callbackNs: Int64
  public var version: Int?
  public var unreadable: Unreadable?

  public init(ptsNs: Int64, callbackNs: Int64, reading: BenchBarcodeReading) {
    self.ptsNs = ptsNs
    self.callbackNs = callbackNs
    switch reading {
    case .version(let version): self.version = version
    case .ambiguousBlock: unreadable = .ambiguousBlock
    case .checksumMismatch: unreadable = .checksumMismatch
    }
  }
}
