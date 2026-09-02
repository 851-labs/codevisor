import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  func model(
    _ client: FakeSessionServerClient,
    sessionId: UUID,
    _ body: (SessionModel) async -> Void
  ) async {
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    await body(model)
  }

  func settleUntil(
    timeout: Duration = .seconds(5),
    _ predicate: () -> Bool
  ) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if predicate() { return }
      // A real delay gives the main-actor event consumer a fair chance
      // to run even when the full Swift suite starts hundreds of tests
      // concurrently. Counting bare yields made the effective timeout
      // depend on runner load and could expire before one actor turn.
      try? await Task.sleep(for: .milliseconds(1))
    }
    guard !predicate() else { return }
    Issue.record("Timed out waiting for SessionModel to settle")
  }

  func userMessages(_ model: SessionModel) -> [UserMessage] {
    model.conversation.compactMap { item in
      if case let .user(message) = item { return message }
      return nil
    }
  }

  func toolCallEnvelope(
    id: Int,
    sessionId: UUID,
    toolCallId: String,
    status: String
  ) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: id,
      serverId: "local",
      kind: "session.output",
      subjectId: sessionId.uuidString,
      createdAt: "2026-06-30T00:00:00.000Z",
      payload: .object([
        "sessionUpdate": .string("tool_call"),
        "toolCallId": .string(toolCallId),
        "title": .string("Edited file"),
        "kind": .string("edit"),
        "status": .string(status),
      ])
    )
  }

  func stopEnvelope(id: Int, sessionId: UUID, stopReason: String) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: id,
      serverId: "local",
      kind: "session.updated",
      subjectId: sessionId.uuidString,
      createdAt: "2026-06-30T00:00:01.000Z",
      payload: .object(["stopReason": .string(stopReason)])
    )
  }

  func cancellationTranscriptPage(
    sessionId: UUID,
    isGenerating: Bool,
    stopReason: String?,
    eventCursor: Int = 2,
    text: String = ""
  ) -> ServerTranscriptPage {
    ServerTranscriptPage(
      items: [
        ServerTranscriptItem(
          id: UUID().uuidString,
          sessionId: sessionId.uuidString,
          sequence: 1,
          role: .assistant,
          text: text,
          createdAt: "2026-07-29T00:00:00.000Z",
          updatedAt: "2026-07-29T00:00:01.000Z",
          isGenerating: isGenerating,
          hasDetails: false,
          turnId: "cancel-turn",
          startedAt: "2026-07-29T00:00:00.000Z",
          endedAt: isGenerating ? nil : "2026-07-29T00:00:01.000Z",
          stopReason: stopReason,
          stopDetail: nil,
          planDocument: nil,
          attachments: nil,
          revision: 2
        )
      ],
      hasMore: false,
      eventCursor: eventCursor
    )
  }

  /// Waits until the model's last assistant turn satisfies the predicate,
  /// so emitted stream events land before assertions run.
  func settleAssistant(_ model: SessionModel, until predicate: (AssistantMessage) -> Bool) async {
    await settleUntil {
      guard case let .assistant(assistant) = model.conversation.last else {
        return false
      }
      return predicate(assistant)
    }
  }
}
