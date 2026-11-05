import Foundation
@preconcurrency import RiveRuntime

struct BotMascotRiveValues: Sendable {
  enum Value: Sendable, Equatable {
    case color(UInt32)
    case choice(String)
    case number(Float)
  }

  let entries: [String: Value]

  init(json data: Data) throws {
    let raw = try JSONDecoder().decode([String: Raw].self, from: data)
    entries = raw.mapValues(\.value)
  }

  @MainActor
  func apply(to instance: ViewModelInstance) {
    for (path, value) in entries {
      switch value {
      case let .color(argb): instance.setValue(of: ColorProperty(path: path), to: Color(argb))
      case let .choice(id): instance.setValue(of: EnumProperty(path: path), to: id)
      case let .number(number): instance.setValue(of: NumberProperty(path: path), to: number)
      }
    }
  }

  private enum Raw: Decodable {
    case text(String)
    case number(Float)

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let number = try? container.decode(Float.self) {
        self = .number(number)
      } else {
        self = .text(try container.decode(String.self))
      }
    }

    var value: Value {
      switch self {
      case let .number(number): .number(number)
      case let .text(text): Self.color(text).map(Value.color) ?? .choice(text)
      }
    }

    private static func color(_ text: String) -> UInt32? {
      guard text.count == 8, text.allSatisfy(\.isHexDigit), text == text.uppercased() else { return nil }
      return UInt32(text, radix: 16)
    }
  }
}
