import Foundation

public enum SessionCreator: String, Sendable, Codable, Equatable {
  case agent
  case user

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = SessionCreator(rawValue: value) ?? .user
  }
}
