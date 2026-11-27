import CodevisorClient
import Foundation

struct BotMascotColorTable: Sendable {
  static let defaultColor = "sunny"
  static let none = "none"

  private typealias ColorsByBody = [String: [String]]
  private typealias ColorsByChoice = [String: ColorsByBody]

  private let categories: [String: [String: ColorsByChoice]]

  init(json data: Data) throws {
    categories = try JSONDecoder().decode([String: [String: ColorsByChoice]].self, from: data)
  }

  func drawable(_ mascot: ServerBotMascot) -> ServerBotMascot {
    let hat = known(mascot.hat, in: "hat")
    let eyewear = known(mascot.eyewear, in: "eyewear")
    return ServerBotMascot(
      color: knownBody(mascot.color),
      hat: hat,
      hatColor: known(mascot.hatColor, for: hat, in: "hat"),
      eyewear: eyewear,
      eyewearColor: known(mascot.eyewearColor, for: eyewear, in: "eyewear"))
  }

  func colors(of item: String, in category: String, choice: String, body: String) -> [String] {
    guard let byChoice = categories[category]?[item] else { return [] }
    return (byChoice[choice] ?? byChoice[ServerBotMascot.autoColor])?[body] ?? []
  }

  private func knownBody(_ color: String) -> String {
    colors(of: "body", in: "body", choice: ServerBotMascot.autoColor, body: color).isEmpty ? Self.defaultColor : color
  }

  private func known(_ item: String, in category: String) -> String {
    categories[category]?[item] == nil ? BotMascotColorTable.none : item
  }

  private func known(_ choice: String, for item: String, in category: String) -> String {
    categories[category]?[item]?[choice] == nil ? ServerBotMascot.autoColor : choice
  }
}
