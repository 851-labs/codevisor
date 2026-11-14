import Foundation

public struct ServerScreenSharingApp: Codable, Sendable, Equatable {
  public let key: String
  public let name: String

  public init(key: String, name: String) {
    self.key = key
    self.name = name
  }
}
