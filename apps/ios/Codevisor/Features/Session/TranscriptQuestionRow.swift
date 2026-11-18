import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit

struct TranscriptQuestionRow: View {
  let interaction: TranscriptInteraction
  let inBotConversation: Bool
  let controller: SessionController

  var body: some View {
    switch interaction.content {
    case let .question(question):
      if question.answer == nil {
        TranscriptQuestionCard(controller: controller, request: question.request, inBotConversation: inBotConversation)
      } else {
        TranscriptQuestionSummaryView(question: question, inBotConversation: inBotConversation)
      }
    case let .pluginSetup(setup):
      if let request = ServerPluginSetupRequest.decoded(from: setup.request) {
        PluginSetupRow(setup: setup, request: request, inBotConversation: inBotConversation, controller: controller)
      }
    }
  }
}
