import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Server-backed config updates paint before the request completes")
  func serverBackedConfigUpdate() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
    client.holdConfigUpdates(until: gate)
    let option = SessionConfigOption(
      id: "model",
      name: "Model",
      category: "model",
      currentValue: "small",
      options: [
        SessionConfigSelectOption(value: "small", name: "Small"),
        SessionConfigSelectOption(value: "large", name: "Large"),
      ]
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      configOptions: [option]
    )

    let update = Task { await model.setConfigOption(configId: "model", value: "large") }
    await settleUntil { !client.configUpdates.isEmpty }

    #expect(client.configUpdates.count == 1)
    #expect(client.configUpdates.first?.0 == "model")
    #expect(client.configUpdates.first?.1 == "large")
    #expect(model.configOptions.first?.currentValue == "large")

    continuation.yield()
    continuation.finish()
    #expect(await update.value)
  }

  @Test("A rejected config update rolls back its optimistic selection")
  func rejectedServerBackedConfigUpdate() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.failNextConfigUpdate()
    let option = SessionConfigOption(
      id: "effort",
      name: "Reasoning",
      category: "thought_level",
      currentValue: "low",
      options: [
        SessionConfigSelectOption(value: "low", name: "Low"),
        SessionConfigSelectOption(value: "xhigh", name: "X-High"),
      ]
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      configOptions: [option]
    )

    let accepted = await model.setConfigOption(configId: "effort", value: "xhigh")

    #expect(!accepted)
    #expect(model.configOptions.first?.currentValue == "low")
  }

  @Test("Fresh harness capabilities replace draft model options")
  func refreshedCapabilitiesReplaceConfigOptions() {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let original = SessionConfigOption(
      id: "model",
      name: "Model",
      category: "model",
      currentValue: "old",
      options: [SessionConfigSelectOption(value: "old", name: "Old")]
    )
    let refreshed = SessionConfigOption(
      id: "model",
      name: "Model",
      category: "model",
      currentValue: "new",
      options: [SessionConfigSelectOption(value: "new", name: "New")]
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      configOptions: [original]
    )

    model.replaceConfigOptions([refreshed])

    #expect(model.configOptions == [refreshed])
  }

  @Test("History paints the persisted answer and loads tools only on disclosure")
  func loadHistoryRestoresState() async {
    let sessionId = UUID()
    let assistantId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [
        transcriptStateItem(sessionId: sessionId, role: .user, text: "edit the file"),
        transcriptStateItem(id: assistantId, sessionId: sessionId, text: "Done.", messageId: "m1", hasDetails: true),
      ], hasMore: false, eventCursor: 99)
    client.transcriptDetailsByItem[assistantId.uuidString] = ServerTranscriptItemDetails(
      itemId: assistantId.uuidString, revision: 1, eventCursor: 99,
      entries: [
        .init(
          key: "tool:edit-1", position: 2, revision: 2,
          payload: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("edit-1"),
            "title": .string("Edited a.txt"), "kind": .string("edit"), "status": .string("completed"),
            "diffStats": .array([.object(["path": .string("a.txt"), "added": .number(3), "removed": .number(1)])]),
          ]))
      ])
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId), sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    await model.loadHistory()
    #expect(model.conversation.count == 2)
    #expect(userMessages(model).first?.text == "edit the file")
    #expect(client.transcriptDetailRequestCount == 0)
    #expect(await model.loadTranscriptDetails(itemId: assistantId.uuidString))
    guard case let .assistant(assistant) = model.conversation.last else { Issue.record("expected assistant"); return }
    #expect(assistant.turn.toolCalls.count == 1)
    #expect(assistant.turn.toolCalls.first?.diffStats?.first?.added == 3)
    #expect(assistant.turn.finalText == .text(id: "acp:m1", markdown: "Done."))
    #expect(!model.isSending)
    await client.eventReads.wait()
    #expect(client.sessionEventSinceValues == [99])
  }

  @Test("History restores selections without replacing the current config catalog")
  func historyKeepsCurrentConfigCatalog() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let currentOptions = [
      SessionConfigOption(
        id: "model",
        name: "Model",
        category: "model",
        currentValue: "gpt-5.6-sol",
        options: [
          SessionConfigSelectOption(value: "gpt-5.6-sol", name: "GPT-5.6-Sol"),
          SessionConfigSelectOption(value: "gpt-5.5", name: "GPT-5.5"),
          SessionConfigSelectOption(value: "gpt-5.6-terra", name: "GPT-5.6-Terra"),
        ]
      ),
      SessionConfigOption(
        id: "effort",
        name: "Reasoning",
        category: "thought_level",
        currentValue: "high",
        options: [
          SessionConfigSelectOption(value: "low", name: "Low"),
          SessionConfigSelectOption(value: "high", name: "High"),
          SessionConfigSelectOption(value: "xhigh", name: "X-High"),
        ]
      ),
    ]
    var savedOptions = currentOptions
    savedOptions[0].currentValue = "gpt-5.5"
    savedOptions[1].currentValue = "xhigh"
    var page = ServerTranscriptPage(items: [], hasMore: false, eventCursor: 1)
    page.stateUpdates = [.configOptionUpdate(savedOptions)]
    client.initialTranscriptPage = page
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      configOptions: currentOptions
    )

    await model.loadHistory()

    let modelOption = model.configOptions.first { $0.id == "model" }
    #expect(modelOption?.options.map(\.value) == ["gpt-5.6-sol", "gpt-5.5", "gpt-5.6-terra"])
    #expect(modelOption?.currentValue == "gpt-5.5")
    #expect(model.configOptions.first { $0.id == "effort" }?.currentValue == "xhigh")
    #expect(client.configUpdates.isEmpty)
  }
}
