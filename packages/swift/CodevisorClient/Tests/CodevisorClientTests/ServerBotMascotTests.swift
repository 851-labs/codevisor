import Foundation
import Testing

@testable import CodevisorClient

@Suite("Bot mascot")
struct ServerBotMascotTests {
  struct WearRow: CustomTestStringConvertible, Sendable {
    let name: String
    let item: ServerBotMascotOptions.Choice
    let hatColor: String
    var testDescription: String { name }
  }

  static let fabric = ["red", "blue"].map { ServerBotMascotOptions.Swatch(id: $0, title: $0, hex: "#000000") }
  static let beanie = ServerBotMascot(color: "mint", hat: "beanie", hatColor: "red", eyewear: "none")

  static let wearRows = [
    WearRow(
      name: "keeps a color the next hat offers",
      item: .init(id: "party", title: "Party hat", swatches: fabric, hasAuto: true), hatColor: "red"),
    WearRow(name: "resets a color the next hat lacks", item: .init(id: "crown", title: "Crown"), hatColor: "auto"),
  ]

  @Test("Reads a mascot from a server without item colors as Auto")
  func decodesOlderServer() throws {
    let json = Data(#"{"color":"mint","hat":"beanie","eyewear":"specs"}"#.utf8)

    let mascot = try JSONDecoder().decode(ServerBotMascot.self, from: json)

    #expect(mascot == ServerBotMascot(color: "mint", hat: "beanie", hatColor: "auto", eyewear: "specs"))
  }

  @Test("Asks for a chosen item color in the art URL and leaves Auto out")
  func artPath() {
    let path = ServerBotMascotArt(Self.beanie, .portrait).path

    #expect(path.contains("hatColor=red"))
    #expect(!path.contains("eyewearColor"))
  }

  @Test("Switching hats", arguments: wearRows)
  func wearing(row: WearRow) {
    let worn = Self.beanie.wearing(row.item, on: .hat)

    #expect(worn.hat == row.item.id)
    #expect(worn.hatColor == row.hatColor)
  }

  @Test("Shows the first swatch for Auto on an item without an Auto color")
  func shownSwatch() {
    let wizard = ServerBotMascotOptions.Choice(id: "wizard", title: "Wizard hat", swatches: Self.fabric)
    let party = ServerBotMascotOptions.Choice(id: "party", title: "Party hat", swatches: Self.fabric, hasAuto: true)

    #expect(wizard.shownSwatch(for: "auto") == "red")
    #expect(party.shownSwatch(for: "auto") == "auto")
    #expect(wizard.shownSwatch(for: "blue") == "blue")
  }
}
