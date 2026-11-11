import Foundation

enum TranscriptBotAppMessages {
  static func messages(in input: TranscriptProjectionInput) -> [TranscriptBotMessage] {
    (input.settledConversation + [input.activeItem].compactMap(\.self)).flatMap { item -> [TranscriptBotMessage] in
      guard case let .assistant(message) = item else { return [] }
      return messages(of: message)
    }
  }

  private static func messages(of message: AssistantMessage) -> [TranscriptBotMessage] {
    let turn = message.turn
    return TranscriptPluginApps.apps(of: turn).map { app in
      TranscriptBotMessage(
        id: "\(message.id.uuidString.lowercased()):app:\(app.viewId)", sender: .bot, text: "", attachments: [],
        sentAt: turn.endedAt ?? turn.startedAt, delivery: nil, files: [], isTranscriptMarkdown: true, app: app)
    }
  }
}
