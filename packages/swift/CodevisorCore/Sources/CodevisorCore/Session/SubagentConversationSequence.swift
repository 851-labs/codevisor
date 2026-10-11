import TranscriptKit

/// Orders parent pieces and groups the agent’s instructions and work into runs.
@MainActor
enum SubagentConversationSequence {
  struct Run {
    var entries: [TranscriptEntry] = []
    var first: AssistantTurn?
    var last: AssistantTurn?
    var lastRunId: String?
  }
  enum Step {
    /// A message to the agent; with no text to show, it only separates runs.
    case instruction(key: String, text: String?)
    case run(Run)
  }

  static func steps(of thread: SubagentThreadCollector.Thread) -> [Step] {
    let pieces = orderedPieces(thread.pieces)
    var steps: [Step] = []
    if let prompt = thread.prompt, !prompt.isEmpty { steps.append(.instruction(key: "prompt", text: prompt)) }
    var current = Run()
    func closeRun() {
      if !current.entries.isEmpty { steps.append(.run(current)) }
      current = Run()
    }
    for piece in pieces {
      switch piece {
      case let .followUp(key, text, _):
        closeRun()
        steps.append(.instruction(key: "follow-up:\(key)", text: text))
      case let .work(entry, _, runId, turn):
        current.entries.append(entry)
        current.first = current.first ?? turn
        current.last = turn
        current.lastRunId = runId
      }
    }
    closeRun()

    return steps
  }

  private static func orderedPieces(
    _ original: [SubagentThreadCollector.Piece]
  ) -> [SubagentThreadCollector.Piece] {
    var pieces = original
    if pieces.allSatisfy({ $0.position != nil }) {
      pieces = pieces.enumerated().sorted { lhs, rhs in
        let (l, r) = (lhs.element.position ?? 0, rhs.element.position ?? 0)
        return l == r ? lhs.offset < rhs.offset : l < r
      }.map(\.element)
    }

    return pieces
  }
}
