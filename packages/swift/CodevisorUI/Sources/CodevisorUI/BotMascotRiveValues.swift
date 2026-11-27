import CodevisorClient
import Foundation
@preconcurrency import RiveRuntime

struct BotMascotRiveValues: Sendable, Equatable {
  enum Value: Sendable, Equatable {
    case color(UInt32)
    case choice(String)
    case number(Float)
  }

  private struct Slot {
    let prefix: String
    let category: String
    let item: String
    let choice: String
  }

  let entries: [String: Value]

  init(_ mascot: ServerBotMascot, colors: BotMascotColorTable) {
    let look = colors.drawable(mascot)
    var entries = Self.choices(of: look)
    for slot in Self.slots(of: look) {
      let values = colors.colors(of: slot.item, in: slot.category, choice: slot.choice, body: look.color)
      for (index, hex) in values.enumerated() {
        entries["\(slot.prefix)\(index)"] = UInt32(hex, radix: 16).map(Value.color)
      }
    }
    self.entries = entries
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

  private static func choices(of look: ServerBotMascot) -> [String: Value] {
    [
      "hat": .choice(look.hat),
      "outfit": .choice(BotMascotColorTable.none),
      "face/eyewear": .choice(look.eyewear),
      "face/lashesOn": .number(0),
      "face/blushOn": .number(0),
      "face/frecklesOn": .number(0),
    ]
  }

  private static func slots(of look: ServerBotMascot) -> [Slot] {
    let auto = ServerBotMascot.autoColor
    let always = [
      Slot(prefix: "body", category: "body", item: "body", choice: auto),
      Slot(prefix: "face/face", category: "face", item: "face", choice: auto),
      Slot(prefix: "face/blush", category: "blush", item: "blush", choice: auto),
      Slot(prefix: "face/freckles", category: "freckles", item: "freckles", choice: auto),
      Slot(prefix: "phone", category: "phone", item: "phone", choice: auto),
      Slot(prefix: "clipboard", category: "clipboard", item: "clipboard", choice: auto),
      Slot(prefix: "watch", category: "watch", item: "watch", choice: auto),
    ]
    return always + worn(look.hat, look.hatColor, prefix: "hat", category: "hat")
      + worn(look.eyewear, look.eyewearColor, prefix: "face/eyewear", category: "eyewear")
  }

  private static func worn(_ item: String, _ choice: String, prefix: String, category: String) -> [Slot] {
    guard item != BotMascotColorTable.none else { return [] }
    return [Slot(prefix: prefix, category: category, item: item, choice: choice)]
  }
}
