import ACPKit

public struct TranscriptInteraction: Sendable, Equatable, Identifiable {
  public enum Content: Sendable, Equatable {
    case question(TranscriptQuestion)
  }

  public var id: String
  public var content: Content

  public init(id: String, content: Content) {
    self.id = id
    self.content = content
  }

  public var isPending: Bool {
    switch content {
    case let .question(question): question.answer == nil
    }
  }
}
