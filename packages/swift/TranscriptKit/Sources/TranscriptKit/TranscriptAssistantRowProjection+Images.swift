extension TranscriptAssistantRowProjection {
  static func hasStopDetailWithoutAnswer(_ message: AssistantMessage) -> Bool {
    !message.turn.isGenerating
      && message.turn.finalText == nil
      && message.turn.attachments.isEmpty
      && message.turn.generatedImageActivity.isEmpty
      && message.turn.stopDetail != nil
  }

  static func appendImageGenerationResponse(
    _ message: AssistantMessage,
    waitingOnBackgroundTask: String?,
    lifecycle: TranscriptBlockLifecycle,
    to rows: inout [TranscriptPresentationRow]
  ) -> Bool {
    guard !message.turn.generatedImageActivity.isEmpty else { return false }
    rows.append(
      .init(
        id: resultID(messageID: message.id, lifecycle: lifecycle),
        content: .assistantResult(message, waitingOnBackgroundTask: waitingOnBackgroundTask),
        estimatedHeight: 200,
        measurementRevision: measurementRevision(
          for: .assistant(message), waitingOnBackgroundTask: waitingOnBackgroundTask)
      ))
    return true
  }

  static func responseText(_ turn: AssistantTurn) -> (String, String)? {
    if case let .text(id, text)? = turn.finalText { return (id, text) }
    return turn.attachments.isEmpty ? nil : ("attachments", "")
  }
}
