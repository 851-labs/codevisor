import Foundation

public struct ScreenSharingStartSigner: Sendable {
  public let key: String
  public let sign: @Sendable (Data) throws -> Data

  public init(key: String, sign: @escaping @Sendable (Data) throws -> Data) {
    self.key = key
    self.sign = sign
  }
}
