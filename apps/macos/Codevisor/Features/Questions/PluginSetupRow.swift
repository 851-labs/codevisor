import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit

struct PluginSetupRow: View {
  @Environment(AppEnvironment.self) private var environment
  let question: TranscriptQuestion
  let request: ServerPluginSetupRequest
  let inBotConversation: Bool
  let controller: SessionController

  var body: some View {
    PluginSetupHost(
      request: request,
      resolution: PluginSetupResolution(question.answer),
      machineId: controller.project.serverId,
      client: environment.machines.client(for: controller.project.serverId),
      inBotConversation: inBotConversation,
      onDecline: decline
    ) { editing, accounts in
      PluginAccountEditorSheet(editing: editing, model: accounts)
    }
  }

  private func decline() {
    let id = question.request.questionId
    guard let spec = question.request.questions.first else { return }
    let answer = QuestionAnswerEntry(answers: [PluginSetupResolution.declineLabel])
    Task { await controller.answerTranscriptQuestion(id, with: [spec.id: answer]) }
  }
}
