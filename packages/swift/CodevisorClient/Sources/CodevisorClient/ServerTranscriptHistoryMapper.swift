import ACPKit
import Foundation
import TranscriptKit

nonisolated enum ServerTranscriptHistoryMapper {
  static func historyPage(from page: ServerTranscriptPage) -> TranscriptHistoryPage {
    TranscriptHistoryPage(
      conversation: page.items
        .map(conversationItem(from:))
        .filter(\.hasRenderableTranscriptContent),
      nextBefore: page.nextBefore,
      hasMore: page.hasMore,
      setupPhases: page.setupActivities.map(\.phase),
      stateUpdates: page.stateUpdates,
      eventCursor: page.eventCursor,
      pendingQuestion: page.pendingQuestion,
      pendingPlanApproval: page.pendingPlanApproval,
      backgroundTasks: page.backgroundTasks,
      goal: page.goal,
      skills: page.skills,
      sessionPlan: page.sessionPlan,
      usage: page.usage?.sessionUsage,
      updateGateHarnessName: page.updateGate?.harnessName,
      autoResume: page.autoResume?.sessionAutoResume
    )
  }

  static func detailEvents(from details: ServerTranscriptItemDetails, sessionId: UUID) -> [ServerSessionStreamEvent] {
    details.entries.flatMap { entry in
      ServerSessionEventDecoder.decode(from: outputEnvelope(of: entry, sessionId: sessionId))
    }
  }

  private static func outputEnvelope(of entry: ServerTranscriptEntry, sessionId: UUID) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: entry.revision, serverId: "", kind: "session.output", subjectId: sessionId.uuidString,
      createdAt: "", payload: entry.payload)
  }

  private static func conversationItem(from item: ServerTranscriptItem) -> ConversationItem {
    let id = uuid(from: item.id)
    switch item.role {
    case .user:
      return .user(userMessage(from: item, id: id))
    case .assistant:
      return .assistant(AssistantMessage(id: id, turn: assistantTurn(from: item)))
    }
  }

  private static func userMessage(from item: ServerTranscriptItem, id: UUID) -> UserMessage {
    UserMessage(
      id: item.messageId.flatMap(UUID.init(uuidString:)) ?? id,
      text: item.text,
      attachments: (item.attachments ?? []).map(\.attachment),
      textResource: resource(item.textResource, largerThan: item.text),
      isEvent: item.isEvent,
      attribution: item.attribution
    )
  }

  private static func assistantTurn(from item: ServerTranscriptItem) -> AssistantTurn {
    let textId = item.messageId.map { "acp:\($0)" } ?? "summary:\(item.id)"
    var turn = summaryTurn(from: item, textId: textId)
    addTextState(of: item, textId: textId, to: &turn)
    turn.setupRequests = (item.setupRequests ?? []).compactMap(\.transcriptRequest)
    turn.interactions = TranscriptInteractions((item.interactions ?? []).compactMap(\.transcriptInteraction))
    turn.pluginApps = item.apps ?? []
    addPlanState(of: item, to: &turn)
    return turn
  }

  private static func summaryTurn(from item: ServerTranscriptItem, textId: String) -> AssistantTurn {
    AssistantTurn(
      entries: textEntries(of: item, textId: textId),
      attachments: (item.attachments ?? []).map(\.attachment),
      isGenerating: item.isGenerating,
      isThinking: item.isGenerating && item.text.isEmpty,
      stopReason: item.stopReason.flatMap(StopReason.init(rawValue:)),
      stopDetail: item.stopDetail,
      stopKind: item.stopKind,
      retryable: item.retryable == true,
      planDocument: item.planDocument,
      startedAt: item.startedAt.flatMap(parseServerDate),
      endedAt: item.endedAt.flatMap(parseServerDate),
      textPhases: textPhases(of: item, textId: textId),
      deferredDetailItemId: item.hasDetails ? item.id : nil,
      hasDeferredWorkedDetails: item.hasDetails,
      detailRevision: item.revision
    )
  }

  private static func textEntries(of item: ServerTranscriptItem, textId: String) -> [TranscriptEntry] {
    guard !item.text.isEmpty else { return [] }
    return [.text(id: textId, markdown: item.text)]
  }

  private static func textPhases(of item: ServerTranscriptItem, textId: String) -> [String: MessagePhase] {
    guard !item.text.isEmpty, let phase = item.phase else { return [:] }
    return [textId: phase]
  }

  private static func addTextState(of item: ServerTranscriptItem, textId: String, to turn: inout AssistantTurn) {
    if let position = item.textPosition { turn.entryPositions["text:\(textId)"] = position }
    turn.textStates[":\(textId)"] = TranscriptTextState(
      generation: item.textGeneration ?? 0, revision: item.textRevision ?? 0,
      resource: resource(item.textResource, largerThan: item.text)
    )
  }

  private static func addPlanState(of item: ServerTranscriptItem, to turn: inout AssistantTurn) {
    turn.planProposedAt = item.planProposedAt.flatMap(parseServerDate)
    turn.planResumedAt = item.planResumedAt.flatMap(parseServerDate)
    turn.planResource = resource(item.planResource, largerThan: item.planDocument)
  }

  private static func resource(_ resource: ToolDetailResource?, largerThan inlineText: String?) -> ToolDetailResource? {
    guard let resource, holdsMore(resource, than: inlineText) else { return nil }
    return resource
  }

  private static func holdsMore(_ resource: ToolDetailResource, than inlineText: String?) -> Bool {
    (resource.fields.first?.sizeBytes ?? 0) > (inlineText?.utf16.count ?? 0) * 2
  }

  private static func parseServerDate(_ value: String) -> Date? {
    try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
  }

  private static func uuid(from id: String) -> UUID {
    UUID(uuidString: id) ?? UUID()
  }
}
