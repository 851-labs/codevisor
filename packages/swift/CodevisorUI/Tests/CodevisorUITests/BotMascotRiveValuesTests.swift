import CodevisorCore
import Foundation
import Testing

@testable import CodevisorUI

@Suite("Bot mascot Rive values")
@MainActor
struct BotMascotRiveValuesTests {
  private struct Fixture: Decodable {
    struct Look: Decodable {
      let mascot: ServerBotMascot
      let values: [String: Raw]
    }

    let riveValues: [Look]
    let framing: [String: [Double]]
  }

  private enum Raw: Decodable, Equatable {
    case text(String)
    case number(Double)

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let number = try? container.decode(Double.self) {
        self = .number(number)
      } else {
        self = .text(try container.decode(String.self))
      }
    }

    init(_ value: BotMascotRiveValues.Value) {
      switch value {
      case let .color(argb): self = .text(String(format: "%08X", argb))
      case let .choice(id): self = .text(id)
      case let .number(number): self = .number(Double(number))
      }
    }
  }

  @Test("The apps dress a mascot with the same values the server package computes")
  func matchesServerPackage() async throws {
    let colors = try await BotMascotArtwork.shared.colorTable()

    for look in try Self.fixture().riveValues {
      let values = BotMascotRiveValues(look.mascot, colors: colors).entries.mapValues(Raw.init)
      #expect(values == look.values, "\(look.mascot)")
    }
  }

  @Test("The apps frame stills the way the server package frames them")
  func matchesServerFraming() throws {
    let framing = try Self.fixture().framing

    #expect(Self.rect(framing["figure"]) == BotMascotFraming.figureBox)
    #expect(Self.rect(framing["portrait"]) == BotMascotFraming.portraitBox)
    #expect(Self.rect(framing["portraitWithHat"]) == BotMascotFraming.portraitWithHatBox)
  }

  @Test("A look from a newer server draws its parts this app knows and leaves out the rest")
  func unknownPartsFromNewerServer() async throws {
    let colors = try await BotMascotArtwork.shared.colorTable()
    let newer = ServerBotMascot(
      color: "ultraviolet", hat: "jetpack", hatColor: "red", eyewear: "goggles", eyewearColor: "holographic")

    #expect(
      colors.drawable(newer)
        == ServerBotMascot(color: "sunny", hat: "none", hatColor: "auto", eyewear: "goggles", eyewearColor: "auto"))
  }

  private static func fixture() throws -> Fixture {
    let url = try #require(
      Bundle.module.url(forResource: "bot-mascot-rive-values", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }

  private static func rect(_ box: [Double]?) -> CGRect? {
    guard let box, box.count == 4 else { return nil }
    return CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
  }
}
