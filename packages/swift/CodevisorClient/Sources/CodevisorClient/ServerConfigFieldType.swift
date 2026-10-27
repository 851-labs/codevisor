import Foundation

public enum ServerConfigFieldType: String, Codable, Sendable {
  case string
  case secret
  case url
  case number
  case boolean
  case choice
  case machine

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = ServerConfigFieldType(rawValue: raw) ?? .string
  }
}
