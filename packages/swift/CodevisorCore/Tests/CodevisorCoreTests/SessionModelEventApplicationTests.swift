import Foundation
import Testing
import ACPKit

@testable import CodevisorClient
@testable import CodevisorCore

@MainActor
struct SessionModelEventApplicationTests {
  private let sessionID = UUID()
  private let clock = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("A finalized assistant message replaces the streamed draft in the active turn")
  func finalizedMessageReplacesDraft() throws {
    let model = makeModel()
    defer { model.shutdown() }
    let attachment = Attachment(fileId: "f1", name: "plot.png", mimeType: "image/png", sizeBytes: 10, kind: .image)

    model.apply(.update(.agentMessageChunk(.text("Draf"))))
    model.apply(.assistantFinalized(markdown: "Done.", messageId: nil, attachments: [attachment]))

    let turn = try #require(activeTurn(model))
    #expect(texts(turn) == ["Done."])
    #expect(turn.attachments == [attachment])
    #expect(model.isSending)
  }

  @Test("Session state events update commands, mode, usage, update gate, plan approval and model fallback")
  func sessionStateEvents() {
    let model = makeModel(modeState: SessionModeState(currentModeId: "ask", availableModes: []))
    defer { model.shutdown() }
    var approvals: [Bool] = []
    model.onPlanApprovalChanged = { approvals.append($0) }
    let command = AvailableCommand(name: "review", description: "Review changes")
    let fallback = SessionModelFallback(originalModel: "large", fallbackModel: "small")

    model.apply(.update(.availableCommandsUpdate([command])))
    model.apply(.update(.currentModeUpdate(currentModeId: "code")))
    model.apply(.update(.usageUpdate(SessionUsage(used: 5, size: 10))))
    model.apply(.updateGate(waiting: true, harnessName: "claude"))
    model.apply(.planApprovalRequired(true))
    model.apply(.modelFallback(fallback))

    #expect(model.availableCommands == [command])
    #expect(model.modeState?.currentModeId == "code")
    #expect(model.usage == SessionUsage(used: 5, size: 10))
    #expect(model.updateGateHarnessName == "claude")
    #expect(model.pendingPlanApproval)
    #expect(approvals == [true])
    #expect(model.modelFallback == fallback)
    #expect(model.conversation.isEmpty)

    model.apply(.updateGate(waiting: false, harnessName: "claude"))
    model.clearModelFallback()

    #expect(model.updateGateHarnessName == nil)
    #expect(model.modelFallback == nil)
  }

  @Test("A late tool update reaches its turn after that turn adopted the server's item id")
  func lateToolUpdateFollowsAdoptedItemId() throws {
    let model = makeModel()
    defer { model.shutdown() }
    let serverItemID = UUID()

    model.apply(.update(.toolCall(ToolCall(toolCallId: "read-1", title: "Read", status: .inProgress))))
    model.apply(.assistantItemStarted(serverItemID))
    model.apply(.userMessage(id: UUID().uuidString, text: "next", attachments: []))
    model.apply(.update(.toolCallUpdate(ToolCallUpdate(toolCallId: "read-1", status: .completed))))

    let settled = try #require(assistantTurn(model, id: serverItemID))
    #expect(settled.allToolCalls.map(\.status) == [.completed])
    #expect(activeTurn(model)?.allToolCalls.isEmpty == true)
  }

  @Test("Tool updates keep reaching resident turns after the route table grows past its limit")
  func toolRoutesSurvivePruning() throws {
    let model = makeModel()
    defer { model.shutdown() }
    let serverItemID = UUID()
    let callIDs = (0...1025).map { "call-\($0)" }

    model.apply(.assistantItemStarted(serverItemID))
    for id in callIDs {
      model.apply(.update(.toolCall(ToolCall(toolCallId: id, title: id, status: .inProgress))))
    }
    model.apply(.userMessage(id: UUID().uuidString, text: "next", attachments: []))
    model.apply(.update(.toolCallUpdate(ToolCallUpdate(toolCallId: "call-0", status: .completed))))

    let settled = try #require(assistantTurn(model, id: serverItemID))
    #expect(settled.allToolCalls.first?.status == .completed)
    #expect(activeTurn(model)?.allToolCalls.isEmpty == true)
  }

  @Test("A revised plan document is stamped as proposed, and answering a question marks it resumed")
  func planProposalAndResume() throws {
    let model = makeModel()
    defer { model.shutdown() }
    let resolution = QuestionResolution(questionId: "q1", outcome: .answered, questions: [])

    model.apply(.update(.planDocument(markdown: "1. Ship it")))
    let proposed = try #require(activeTurn(model))
    #expect(proposed.planProposedAt == clock)
    #expect(proposed.planResumedAt == nil)

    model.apply(.update(.questionResolved(resolution)))
    #expect(activeTurn(model)?.planResumedAt == clock)
  }

  @Test("A remote echo adds the attachments its optimistic user message is missing")
  func echoFillsMissingAttachments() {
    let model = makeModel()
    defer { model.shutdown() }
    let messageID = UUID()
    let attachment = Attachment(fileId: "f1", name: "notes.txt", mimeType: "text/plain", sizeBytes: 4, kind: .file)

    model.apply(.userMessage(id: messageID.uuidString, text: "see file", attachments: []))
    model.apply(.userMessage(id: messageID.uuidString, text: "see file", attachments: [attachment]))

    #expect(users(model).map(\.id) == [messageID])
    #expect(users(model).map(\.attachments) == [[attachment]])
  }

  @Test("Finishing an earlier turn while nothing is generating clears the pending question")
  func finishingEarlierTurnClearsPendingQuestion() throws {
    let model = makeModel()
    defer { model.shutdown() }
    let earlierItemID = UUID()

    model.apply(.assistantItemStarted(earlierItemID))
    model.apply(.update(.agentMessageChunk(.text("Working"))))
    model.apply(.userMessage(id: UUID().uuidString, text: "next", attachments: []))
    model.apply(.finished(.endTurn, stopDetail: nil))
    model.apply(.update(.question(QuestionRequest(questionId: "q1", questions: []))))
    model.apply(.finished(.endTurn, stopDetail: nil, chatItemId: earlierItemID))

    #expect(model.pendingQuestion == nil)
    #expect(model.isSending == false)
    #expect(try #require(assistantTurn(model, id: earlierItemID)).stopReason == .endTurn)
  }

  @Test(
    "A turn ended by a restart keeps its question waiting for an answer", arguments: ["pausedForUpdate", "interrupted"])
  func restartKeepsPendingQuestion(stopKind: String) {
    let model = makeModel()
    defer { model.shutdown() }
    let question = QuestionRequest(questionId: "q1", questions: [])

    model.apply(.update(.agentMessageChunk(.text("One question first"))))
    model.apply(.update(.question(question)))
    model.apply(.finished(.cancelled, stopDetail: nil, stopKind: stopKind))

    #expect(model.pendingQuestion == question)
    #expect(model.isSending == false)
  }

  @Test("A pending stalled-turn check doesn't keep a released session model alive")
  func pendingStallCheckReleasesModel() async {
    let scheduler = ManualSessionQuietTurnScheduler()
    weak var weakModel: SessionModel?
    do {
      let model = makeModel(quietTurnScheduler: scheduler.scheduler)
      weakModel = model
      model.apply(.update(.agentMessageChunk(.text("Working"))))
    }
    #expect(scheduler.callCount == 1)
    #expect(weakModel == nil)

    await scheduler.advance()
    #expect(weakModel == nil)
  }

  private func makeModel(
    modeState: SessionModeState? = nil,
    quietTurnScheduler: SessionQuietTurnScheduler = .continuous
  ) -> SessionModel {
    let clock = clock
    return SessionModel(
      serverTransport: ServerSessionTransport(
        client: FakeSessionServerClient(sessionId: sessionID), sessionId: sessionID),
      sessionId: sessionID.uuidString,
      modeState: modeState,
      now: { clock },
      quietTurnScheduler: quietTurnScheduler
    )
  }

  private func activeTurn(_ model: SessionModel) -> AssistantTurn? {
    guard case let .assistant(message) = model.activeItem else { return nil }
    return message.turn
  }

  private func assistantTurn(_ model: SessionModel, id: UUID) -> AssistantTurn? {
    model.conversation.lazy.compactMap { item -> AssistantTurn? in
      guard case let .assistant(message) = item, message.id == id else { return nil }
      return message.turn
    }.first
  }

  private func users(_ model: SessionModel) -> [UserMessage] {
    model.conversation.compactMap { item in
      if case let .user(message) = item { message } else { nil }
    }
  }

  private func texts(_ turn: AssistantTurn) -> [String] {
    turn.entries.compactMap { entry in
      if case let .text(_, markdown) = entry { markdown } else { nil }
    }
  }
}
