public struct BenchCardCapture: Sendable {
  public enum Kind: Sendable, Equatable {
    case text
    case chroma
  }

  public let version: Int
  public let kind: Kind
  public let reference: BenchRGBImage
  public let shown: BenchRGBImage

  public init(version: Int, kind: Kind, reference: BenchRGBImage, shown: BenchRGBImage) {
    self.version = version
    self.kind = kind
    self.reference = reference
    self.shown = shown
  }
}
