import ACPKit
import CodevisorProtocol
import Foundation
import TranscriptKit

/// Converts server envelopes to ordered session events for live and stored work.
enum ServerSessionEventDecoder {
  static func decode(from event: ServerEventEnvelope) -> [ServerSessionStreamEvent] {
    if let events = synchronizationEvents(from: event) { return events }
    if let events = finalizedAssistantEvents(from: event) { return events }
    if let events = rawSessionUpdateEvents(from: event) { return events }
    return eventsByKind(from: event)
  }

  private static func synchronizationEvents(from event: ServerEventEnvelope) -> [ServerSessionStreamEvent]? {
    if event.kind == "client.synchronization",
      let state = event.payload["state"]?.stringValue.flatMap(SessionStreamSynchronization.init(rawValue:))
    {
      return [.synchronization(state)]
    }
    return nil
  }

  private static func finalizedAssistantEvents(from event: ServerEventEnvelope) -> [ServerSessionStreamEvent]? {
    if event.payload["sessionUpdate"]?.stringValue == "assistant_message_finalized",
      let markdown = event.payload["markdown"]?.stringValue
    {
      return [
        .assistantFinalized(
          markdown: markdown,
          messageId: event.payload["messageId"]?.stringValue,
          attachments: attachments(from: event.payload)
        )
      ]
    }
    return nil
  }

  private static func rawSessionUpdateEvents(from event: ServerEventEnvelope) -> [ServerSessionStreamEvent]? {
    guard let rawUpdate = decodeRawSessionUpdate(event.payload) else { return nil }
    if event.payload["isFinalized"]?.boolValue == true, case let .agentMessagePatch(patch) = rawUpdate {
      return [
        .update(rawUpdate),
        .assistantFinalized(
          markdown: patch.text, messageId: patch.messageId, attachments: attachments(from: event.payload)),
      ]
    }
    return [.update(rawUpdate)]
  }

  private static func eventsByKind(from event: ServerEventEnvelope) -> [ServerSessionStreamEvent] {
    switch event.kind {
    case "session.attention.updated":
      return [
        .planApprovalRequired(
          event.payload["pendingPlanApproval"]?.boolValue == true
        )
      ]
    case "session.queue.updated":
      return [.queueUpdated(promptQueue(from: event.payload))]
    case "session.updateGate.updated":
      return [
        .updateGate(
          waiting: event.payload["state"]?.stringValue == "waiting",
          harnessName: event.payload["harnessName"]?.stringValue
            ?? event.payload["harnessId"]?.stringValue
            ?? "the agent"
        )
      ]
    case "session.output":
      return outputEvents(from: event.payload)
    case "session.updated":
      return updatedSessionEvents(from: event.payload)
    case "session.error":
      return [
        .failed(
          errorMessage(from: event.payload),
          retryable: event.payload["retryable"]?.boolValue == true,
          chatItemId: event.payload["chatItemId"]?.stringValue
            .flatMap(UUID.init(uuidString:))
        )
      ]
    case "session.authRequired":
      return [
        .authenticationRequired(
          event.payload["detail"]?.stringValue
            ?? "Sign-in expired. Sign in again in Harness Settings to continue."
        )
      ]
    default:
      return []
    }
  }

  private static func updatedSessionEvents(from payload: JSONValue) -> [ServerSessionStreamEvent] {
    var updates: [ServerSessionStreamEvent] = []
    if payload["turnState"]?.stringValue == "started",
      let rawItemId = payload["chatItemId"]?.stringValue,
      let itemId = UUID(uuidString: rawItemId)
    {
      updates.append(.assistantItemStarted(itemId))
    }
    if let status = statusEvent(from: payload) { return updates + [status] }
    return updates
      + metadataUpdates(from: payload).map(ServerSessionStreamEvent.update)
  }

  private static func statusEvent(from payload: JSONValue) -> ServerSessionStreamEvent? {
    if let retry = retryStatus(from: payload) {
      return .retrying(retry)
    }
    if let stopReason = stopReason(from: payload) {
      return .finished(
        stopReason,
        stopDetail: payload["stopDetail"]?.stringValue,
        stopKind: payload["stopKind"]?.stringValue,
        retryable: payload["retryable"]?.boolValue == true,
        chatItemId: payload["chatItemId"]?.stringValue
          .flatMap(UUID.init(uuidString:))
      )
    }
    if let tasks = backgroundTasks(from: payload) {
      return .backgroundTasks(tasks)
    }
    if let fallback = modelFallback(from: payload) {
      return .modelFallback(fallback)
    }
    if let state = payload["runtimeState"]?.stringValue
      .flatMap(SessionRuntimeState.init(rawValue:))
    {
      return .runtimeState(state)
    }
    return nil
  }

  /// Shared coders for the `JSONValue` → typed-model bridge below. These
  /// run per streamed event — one per token chunk on the hot path — and a
  /// fresh `JSONEncoder`/`JSONDecoder` allocation per call is measurable
  /// under several concurrent streams. Sharing is safe: both types create
  /// all mutable state per `encode`/`decode` call.
  private static let bridgeEncoder = JSONEncoder()
  private static let bridgeDecoder = JSONDecoder()

  private static func promptQueue(from payload: JSONValue) -> [ServerPromptQueueItem] {
    guard let queue = payload["queue"]?.arrayValue else { return [] }
    do {
      let data = try bridgeEncoder.encode(JSONValue.array(queue))
      return try bridgeDecoder.decode([ServerPromptQueueItem].self, from: data)
    } catch {
      Log.session.error(
        "Failed to decode prompt-queue payload: \(String(describing: error), privacy: .public)"
      )
      return []
    }
  }

  private static func decodeRawSessionUpdate(_ payload: JSONValue) -> SessionUpdate? {
    guard payload["sessionUpdate"] != nil else { return nil }
    do {
      let data = try bridgeEncoder.encode(payload)
      return try bridgeDecoder.decode(SessionUpdate.self, from: data)
    } catch {
      Log.session.error(
        "Failed to decode session-update payload: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private static func outputEvents(from payload: JSONValue) -> [ServerSessionStreamEvent] {
    guard let role = payload["role"]?.stringValue,
      let text = payload["text"]?.stringValue
    else {
      return []
    }
    switch role {
    case "assistant" where !text.isEmpty:
      return [.update(.agentMessageChunk(.text(text), messageId: payload["messageId"]?.stringValue))]
    case "user":
      let attachments = attachments(from: payload)
      guard !text.isEmpty || !attachments.isEmpty else { return [] }
      return [
        .userMessage(
          id: payload["messageId"]?.stringValue,
          text: text,
          attachments: attachments
        )
      ]
    default:
      return []
    }
  }

  private static func attachments(from payload: JSONValue) -> [Attachment] {
    guard let raw = payload["attachments"]?.arrayValue else { return [] }
    do {
      let data = try bridgeEncoder.encode(JSONValue.array(raw))
      return try bridgeDecoder.decode([ServerAttachmentRef].self, from: data).map(\.attachment)
    } catch {
      Log.session.error(
        "Failed to decode attachments payload: \(String(describing: error), privacy: .public)"
      )
      return []
    }
  }

  /// Both model ids are required: a notice that cannot name what was swapped
  /// for what is not worth showing, so a malformed payload is skipped.
  private static func modelFallback(from payload: JSONValue) -> SessionModelFallback? {
    guard let value = payload["modelFallback"],
      let originalModel = value["originalModel"]?.stringValue,
      let fallbackModel = value["fallbackModel"]?.stringValue
    else { return nil }
    return SessionModelFallback(
      originalModel: originalModel,
      fallbackModel: fallbackModel,
      category: value["category"]?.stringValue
    )
  }

  private static func metadataUpdates(from payload: JSONValue) -> [SessionUpdate] {
    if let configOptions = decodeConfigOptions(payload["configOptions"]) {
      return [.configOptionUpdate(configOptions)]
    }
    if let modeId = payload["modeId"]?.stringValue {
      return [.currentModeUpdate(currentModeId: modeId)]
    }
    if let goal = decodeGoal(payload["goal"]) {
      return [.goalUpdate(goal)]
    }
    if payload["goalCleared"]?.boolValue == true {
      return [.goalCleared]
    }
    return []
  }

  private static func decodeGoal(_ value: JSONValue?) -> SessionGoal? {
    guard let value else { return nil }
    do {
      let data = try bridgeEncoder.encode(value)
      return try bridgeDecoder.decode(SessionGoal.self, from: data)
    } catch {
      // Lenient like the other decoders: an unknown status or malformed
      // snapshot degrades to skipping the update.
      Log.session.error(
        "Failed to decode goal payload: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private static func stopReason(from payload: JSONValue) -> StopReason? {
    guard let raw = payload["stopReason"]?.stringValue else { return nil }
    return StopReason(rawValue: raw)
  }

  private static func retryStatus(from payload: JSONValue) -> RetryStatus? {
    guard let retry = payload["retrying"] else { return nil }
    return RetryStatus(
      attempt: retry["attempt"]?.intValue,
      of: retry["of"]?.intValue,
      message: retry["message"]?.stringValue ?? "Server is busy, reconnecting"
    )
  }

  private static func backgroundTasks(from payload: JSONValue) -> [BackgroundTaskInfo]? {
    guard let raw = payload["backgroundTasks"]?.arrayValue else { return nil }
    do {
      let data = try bridgeEncoder.encode(JSONValue.array(raw))
      return try bridgeDecoder.decode([BackgroundTaskInfo].self, from: data)
    } catch {
      Log.session.error(
        "Failed to decode background-tasks payload: \(String(describing: error), privacy: .public)"
      )
      return []
    }
  }

  private static func errorMessage(from payload: JSONValue) -> String {
    payload["message"]?.stringValue ?? "The server reported an error."
  }

  private static func decodeConfigOptions(_ value: JSONValue?) -> [SessionConfigOption]? {
    guard let value else { return nil }
    do {
      let data = try bridgeEncoder.encode(value)
      return try bridgeDecoder.decode([SessionConfigOption].self, from: data)
    } catch {
      Log.session.error(
        "Failed to decode config-options payload: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }
}
