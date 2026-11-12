import Foundation

public struct TranscriptWorkedSectionHeader: Sendable, Equatable {
  public enum Progress: Sendable, Equatable {
    case working(since: Date?, activity: WorkedSectionActivity)
    case worked(title: String)
  }

  public let messageID: UUID
  public let kind: TranscriptWorkedSectionKind
  public let progress: Progress
  public let hasContent: Bool
  public let deferredDetailItemID: String?

  public init(message: AssistantMessage, kind: TranscriptWorkedSectionKind, items: [WorkedItem]) {
    let turn = message.turn
    messageID = message.id
    self.kind = kind
    progress = Self.progress(of: turn, kind: kind)
    hasContent = turn.defersWorkedSection(kind) || !items.isEmpty
    deferredDetailItemID = turn.hasDeferredWorkedDetails ? turn.deferredDetailItemId : nil
  }

  public var isWorking: Bool {
    if case .working = progress { true } else { false }
  }

  private static func progress(of turn: AssistantTurn, kind: TranscriptWorkedSectionKind) -> Progress {
    guard turn.workedSectionTicks(kind) else { return .worked(title: turn.workedSectionSettledTitle(kind)) }

    return .working(since: turn.workedSectionStart(kind), activity: turn.workedSectionActivity)
  }
}
