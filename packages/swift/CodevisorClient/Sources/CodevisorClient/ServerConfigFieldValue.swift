import Foundation

public enum ServerConfigFieldValue: Codable, Hashable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let flag = try? container.decode(Bool.self) {
      self = .bool(flag)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .string(text): try container.encode(text)
    case let .number(number): try container.encode(number)
    case let .bool(flag): try container.encode(flag)
    }
  }

  public var text: String {
    switch self {
    case let .string(text): text
    case let .number(number): Self.text(for: number)
    case let .bool(flag): flag ? "true" : "false"
    }
  }

  public var isTrue: Bool {
    if case .bool(true) = self { true } else { false }
  }

  private static func text(for number: Double) -> String {
    guard number == number.rounded(), abs(number) < 1e15 else { return String(number) }
    return String(Int64(number))
  }
}
