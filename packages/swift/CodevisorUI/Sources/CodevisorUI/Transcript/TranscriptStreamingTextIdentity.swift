import CodevisorCore
import Foundation
import StreamMarkdown

public enum TranscriptStreamingTextIdentity {
  public static func restorationID(for item: ConversationItem) -> String? {
    guard case let .assistant(message) = item,
      message.turn.hasHydratedWorkedDetails
    else { return nil }
    return "\(message.id.uuidString):\(message.turn.detailRevision)"
  }

  public static func main(turnID: UUID, entryID: String) -> String {
    "\(turnID.uuidString):main:\(entryID)"
  }

  public static func mainResponseSegment(
    turnID: UUID,
    entryID: String,
    segmentIndex: Int
  ) -> String {
    main(turnID: turnID, entryID: "\(entryID):\(segmentIndex)")
  }

  public static func settledStreamIDs(turn: AssistantTurn, turnID: UUID) -> [String] {
    var result = turn.entries.compactMap { entry -> String? in
      guard case let .text(id, _) = entry else { return nil }
      return main(turnID: turnID, entryID: id)
    }
    if let finalTextIndex = turn.finalTextIndex,
      case let .text(entryID, markdown) = turn.entries[finalTextIndex]
    {
      let segments = assistantMarkdownSegments(
        markdown,
        attachments: turn.attachments,
        includeServerPaths: true,
        includeUnreferencedAttachments: !turn.isGenerating
      )
      for (index, segment) in segments.enumerated() {
        guard case let .markdown(value) = segment, !value.isEmpty else { continue }
        result.append(
          mainResponseSegment(
            turnID: turnID,
            entryID: entryID,
            segmentIndex: index
          ))
      }
    }
    if turn.finalTextIndex == nil, !turn.attachments.isEmpty {
      result.append(main(turnID: turnID, entryID: "attachments"))
    }
    return result
  }
}

public extension StreamingTextAnimationPresentation {
  func establishBaseline(settling turn: AssistantTurn, turnID: UUID) {
    establishBaseline {
      TranscriptStreamingTextIdentity.settledStreamIDs(
        turn: turn,
        turnID: turnID
      )
    }
  }
}
