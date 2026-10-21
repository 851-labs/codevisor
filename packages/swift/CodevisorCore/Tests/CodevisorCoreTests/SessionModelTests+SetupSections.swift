import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

extension SessionModelTests {
  private final class SetupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
      lock.withLock { current += seconds }
    }
  }

  @Test("A setup request ends the running section and a new section starts once it is answered")
  func setupRequestSplitsWorkedSections() throws {
    let clock = SetupClock()
    let sessionId = UUID()
    let model = SessionModel(
      serverTransport: ServerSessionTransport(
        client: FakeSessionServerClient(sessionId: sessionId), sessionId: sessionId),
      sessionId: sessionId.uuidString,
      now: { clock.now }
    )
    let firstSection = UUID()
    let secondSection = UUID()
    let questions = [QuestionSpec(id: "c", question: "Allow", presentation: .computerUsePermissions)]
    func turn(_ id: UUID) -> AssistantTurn? {
      for item in model.conversation {
        if case let .assistant(message) = item, message.id == id { return message.turn }
      }
      return nil
    }

    model.apply(.assistantItemStarted(firstSection))
    var call = ToolCall(toolCallId: "look", title: "look", kind: .fetch, status: .inProgress)
    call.chatItemId = firstSection.uuidString
    model.apply(.update(.toolCall(call)))
    clock.advance(by: 12)
    model.apply(.update(.question(QuestionRequest(questionId: "cu", questions: questions))))
    clock.advance(by: 40)

    let asked = try #require(turn(firstSection))
    #expect(model.activeItem == nil)
    #expect(!asked.isGenerating)
    #expect(asked.workedSectionTitle(.planning, now: clock.now) == "Worked for 12s")
    #expect(asked.setupRequests == [TranscriptSetupRequest(id: "cu", kind: .computerUse, state: .pending)])

    model.apply(
      .update(
        .questionResolved(
          QuestionResolution(
            questionId: "cu", outcome: .answered, questions: questions,
            assistantItemId: secondSection.uuidString))))
    clock.advance(by: 5)

    #expect(turn(firstSection)?.setupRequests.map(\.state) == [.setUp])
    let resumed = try #require(turn(secondSection))
    #expect(model.activeItem?.id == secondSection)
    #expect(resumed.isGenerating)
    #expect(resumed.workedSectionTitle(.planning, now: clock.now) == "Working for 5s")
  }
}
