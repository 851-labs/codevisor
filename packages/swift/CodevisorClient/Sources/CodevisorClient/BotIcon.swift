import Foundation

public struct BotIcon: Identifiable, Hashable, Sendable {
  public let systemImage: String
  public let title: String

  public var id: String { systemImage }

  public static let fallback = BotIcon(systemImage: "sparkles", title: "Sparkles")

  public static let choices: [BotIcon] = [
    fallback,
    BotIcon(systemImage: "brain", title: "Brain"),
    BotIcon(systemImage: "wand.and.stars", title: "Wand"),
    BotIcon(systemImage: "hammer", title: "Hammer"),
    BotIcon(systemImage: "wrench.and.screwdriver", title: "Tools"),
    BotIcon(systemImage: "ant", title: "Ant"),
    BotIcon(systemImage: "ladybug", title: "Ladybug"),
    BotIcon(systemImage: "shield.lefthalf.filled", title: "Shield"),
    BotIcon(systemImage: "magnifyingglass", title: "Magnifier"),
    BotIcon(systemImage: "doc.text", title: "Document"),
    BotIcon(systemImage: "book", title: "Book"),
    BotIcon(systemImage: "paintbrush", title: "Paintbrush"),
    BotIcon(systemImage: "chart.line.uptrend.xyaxis", title: "Chart"),
    BotIcon(systemImage: "bolt", title: "Bolt"),
    BotIcon(systemImage: "flame", title: "Flame"),
    BotIcon(systemImage: "leaf", title: "Leaf"),
    BotIcon(systemImage: "paperplane", title: "Paper Plane"),
    BotIcon(systemImage: "bell", title: "Bell"),
    BotIcon(systemImage: "star", title: "Star"),
    BotIcon(systemImage: "cpu", title: "Chip"),
  ]

  private init(systemImage: String, title: String) {
    self.systemImage = systemImage
    self.title = title
  }

  public init(resolving systemImage: String?) {
    self = Self.choices.first { $0.systemImage == systemImage } ?? Self.fallback
  }
}
