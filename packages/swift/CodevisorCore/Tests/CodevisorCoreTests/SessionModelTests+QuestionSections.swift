import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

extension SessionModelTests {
  @Test("An agent question ends the running section, and a reply sent instead resumes work after the reply")
  func transcriptQuestionSplitsWorkedSections() throws {
    let sessionId = UUID()
    let model = SessionModel(
      serverTransport: ServerSessionTransport(
        client: FakeSessionServerClient(sessionId: sessionId), sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    let firstSection = UUID()
    let resumedSection = UUID()
    let questions = [QuestionSpec(id: "db", question: "Which database?", options: [QuestionOption(label: "Postgres")])]
    let request = QuestionRequest(questionId: "q", questions: questions)
    func turn(_ id: UUID) -> AssistantTurn? {
      model.conversation.lazy.compactMap { item -> AssistantTurn? in
        guard case let .assistant(message) = item, message.id == id else { return nil }
        return message.turn
      }.first
    }

    model.apply(.assistantItemStarted(firstSection))
    model.apply(.update(.question(request)))

    #expect(model.activeItem == nil)
    #expect(model.isSending)
    #expect(model.pendingQuestion == request)
    #expect(turn(firstSection)?.isGenerating == false)
    #expect(turn(firstSection)?.interactions.items.map(\.isPending) == [true])

    model.apply(
      .userMessage(id: UUID().uuidString, text: "Use SQLite", attachments: [], assistantItemId: resumedSection))
    model.apply(
      .update(
        .questionResolved(
          QuestionResolution(
            questionId: "q", outcome: .replied, questions: questions, assistantItemId: resumedSection.uuidString))))

    #expect(model.pendingQuestion == nil)
    #expect(turn(firstSection)?.interactions.items.map(\.isPending) == [false])
    #expect(model.activeItem?.id == resumedSection)
    guard case let .user(reply) = model.settledConversation.last else {
      Issue.record("expected the reply to follow the question's section")
      return
    }
    #expect(reply.text == "Use SQLite")
  }
}
