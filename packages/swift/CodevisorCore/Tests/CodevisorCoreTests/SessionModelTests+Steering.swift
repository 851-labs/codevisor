import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

extension SessionModelTests {
  private final class SteerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
      lock.withLock { current += seconds }
    }
  }

  private func assistantTurn(_ model: SessionModel, id: UUID) -> AssistantTurn? {
    for item in model.conversation {
      if case let .assistant(message) = item, message.id == id { return message.turn }
    }
    return nil
  }

  private func search(_ id: String, _ status: ToolCallStatus, in itemId: UUID) -> SessionUpdate {
    var call = ToolCall(toolCallId: id, title: id, kind: .fetch, status: status)
    call.chatItemId = itemId.uuidString
    return .toolCall(call)
  }

  @Test("A steered message ends the running section and only the section after it stays live")
  func steeredMessageSplitsWorkedSections() throws {
    let clock = SteerClock()
    let sessionId = UUID()
    let model = SessionModel(
      serverTransport: ServerSessionTransport(
        client: FakeSessionServerClient(sessionId: sessionId), sessionId: sessionId),
      sessionId: sessionId.uuidString,
      now: { clock.now }
    )
    let firstSection = UUID()
    let secondSection = UUID()

    model.apply(.assistantItemStarted(firstSection))
    model.apply(.update(search("search-sf", .inProgress, in: firstSection)))
    clock.advance(by: 21)
    model.apply(
      .userMessage(
        id: UUID().uuidString, text: "actually bham al", attachments: [], assistantItemId: secondSection))
    model.apply(.update(search("search-sf", .completed, in: firstSection)))
    model.apply(.update(search("search-bham", .completed, in: secondSection)))
    clock.advance(by: 18)

    let first = try #require(assistantTurn(model, id: firstSection))
    let live = try #require(assistantTurn(model, id: secondSection))
    #expect(model.conversation.map(\.id).suffix(3) == [firstSection, userMessages(model).last?.id, secondSection])
    #expect(!first.isGenerating)
    #expect(first.workedSectionTitle(.planning, now: clock.now) == "Worked for 21s")
    #expect(first.toolCalls.map(\.toolCallId) == ["search-sf"])
    #expect(first.toolCalls.first?.status == .completed)
    #expect(live.isGenerating)
    #expect(live.workedSectionTitle(.planning, now: clock.now) == "Working for 18s")
    #expect(live.toolCalls.map(\.toolCallId) == ["search-bham"])

    model.apply(.finished(.endTurn, stopDetail: nil, chatItemId: secondSection))
    clock.advance(by: 60)

    let ended = try #require(assistantTurn(model, id: secondSection))
    #expect(!model.isSending)
    #expect(assistantTurn(model, id: firstSection)?.workedSectionTitle(.planning, now: clock.now) == "Worked for 21s")
    #expect(ended.workedSectionTitle(.planning, now: clock.now) == "Worked for 18s")
  }
}
