import Foundation

public struct BotMessagePreview: Codable, Equatable, Hashable, Sendable {
  public var text: String
  public var attachmentNames: [String]

  public init(text: String, attachmentNames: [String] = []) {
    self.text = text
    self.attachmentNames = attachmentNames
  }
}
