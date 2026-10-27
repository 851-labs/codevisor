import Foundation

public enum SandboxFieldValue: Codable, Equatable, Hashable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .string(value): try container.encode(value)
    case let .number(value): try container.encode(value)
    case let .bool(value): try container.encode(value)
    }
  }

  public var text: String {
    switch self {
    case let .string(value): value
    case let .number(value): value.formatted(.number.grouping(.never))
    case let .bool(value): value ? "On" : "Off"
    }
  }

  public var stringValue: String? {
    if case let .string(value) = self { return value }
    return nil
  }
}
