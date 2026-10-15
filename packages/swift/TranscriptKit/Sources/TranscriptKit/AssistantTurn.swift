import Foundation
import ACPKit

public struct SubagentTranscript: Sendable, Equatable {
  public var entries: [TranscriptEntry]
  public var isThinking: Bool
  public var nextTextId: Int

  public init(entries: [TranscriptEntry] = [], isThinking: Bool = false, nextTextId: Int = 0) {
    self.entries = entries
    self.isThinking = isThinking
    self.nextTextId = nextTextId
  }
}

public struct RetryStatus: Sendable, Equatable {
  public let attempt: Int?
  public let of: Int?
  public let message: String
  public init(attempt: Int? = nil, of: Int? = nil, message: String = "Server is busy, reconnecting") {
    self.attempt = attempt
    self.of = of
    self.message = message
  }
}

public struct AssistantTurn: Sendable, Equatable {
  public var entries: [TranscriptEntry]
  public var attachments: [Attachment]
  public var isGenerating: Bool
  public var isThinking: Bool
  public var stopReason: StopReason?
  public var stopDetail: String?
  public var stopKind: String?
  public var retryable: Bool
  public var retryStatus: RetryStatus?
  public var plan: Plan?
  public var planDocument: String?
  public var planResource: ToolDetailResource? = nil
  public var planRevision: Int = 0
  public var planBoundary: Int?
  public var planProposedAt: Date? = nil
  public var planResumedAt: Date? = nil
  public var startedAt: Date?
  public var endedAt: Date?
  public var subagents: [String: SubagentTranscript]
  public var textPhases: [String: MessagePhase]
  public var entryPositions: [String: Int] = [:]
  public var callsAfterReasoning: Set<String> = []
  public var textStates: [String: TranscriptTextState] = [:]
  public var deferredDetailItemId: String?
  public var hasDeferredWorkedDetails: Bool
  public var detailRevision: Int
  public var hasHydratedWorkedDetails: Bool
  public var nextTextId: Int

  public init(
    entries: [TranscriptEntry] = [],
    attachments: [Attachment] = [],
    isGenerating: Bool = false,
    isThinking: Bool = false,
    stopReason: StopReason? = nil,
    stopDetail: String? = nil,
    stopKind: String? = nil,
    retryable: Bool = false,
    retryStatus: RetryStatus? = nil,
    plan: Plan? = nil,
    planDocument: String? = nil,
    planBoundary: Int? = nil,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    subagents: [String: SubagentTranscript] = [:],
    textPhases: [String: MessagePhase] = [:],
    deferredDetailItemId: String? = nil,
    hasDeferredWorkedDetails: Bool = false,
    detailRevision: Int = 0,
    hasHydratedWorkedDetails: Bool = false,
    nextTextId: Int = 0
  ) {
    self.entries = entries
    self.attachments = attachments
    self.isGenerating = isGenerating
    self.isThinking = isThinking
    self.stopReason = stopReason
    self.stopDetail = stopDetail
    self.stopKind = stopKind
    self.retryable = retryable
    self.retryStatus = retryStatus
    self.plan = plan
    self.planDocument = planDocument
    self.planBoundary = planBoundary
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.subagents = subagents
    self.textPhases = textPhases
    self.deferredDetailItemId = deferredDetailItemId
    self.hasDeferredWorkedDetails = hasDeferredWorkedDetails
    self.detailRevision = detailRevision
    self.hasHydratedWorkedDetails = hasHydratedWorkedDetails
    self.nextTextId = nextTextId
  }

  public var contextCompactionStatus: ContextCompactionStatus? {
    for entry in entries.reversed() {
      if case let .contextCompaction(_, status) = entry { return status }
    }
    return nil
  }

  public var finalText: TranscriptEntry? {
    guard let index = finalTextIndex else { return nil }
    return entries[index]
  }

  public var finalTextIsAsserted: Bool {
    guard case let .text(id, _) = finalText else { return false }
    return textPhases[id] == .final
  }

  public var workedEntries: [TranscriptEntry] {
    let finalID = finalText?.id
    return entries.compactMap { entry in
      if entry.id == finalID { return nil }
      if case .contextCompaction = entry { return nil }
      if case let .tool(call) = entry, call.kind == .imageGeneration { return nil }
      return entry
    }
  }

  public var toolCalls: [ToolCall] {
    entries.compactMap { if case let .tool(call) = $0 { return call } else { return nil } }
  }

  public var hasRunningToolCall: Bool {
    toolCalls.contains { !$0.isSettled && !isUnstartedSubagent($0) }
  }

  public var showsActivityIndicator: Bool {
    guard isGenerating else { return false }
    if isThinking { return true }
    return finalText == nil && !hasRunningToolCall
  }

  public var reservesActivitySlot: Bool {
    guard isGenerating else { return false }
    return showsActivityIndicator || finalText == nil
  }

  public var allToolCalls: [ToolCall] {
    toolCalls
      + subagents.keys.sorted().flatMap { key in
        (subagents[key]?.entries ?? []).compactMap {
          if case let .tool(call) = $0 { return call } else { return nil }
        }
      }
  }

  public func startedRunningSubagent(_ runToolCallIds: Set<String>) -> Bool {
    guard !runToolCallIds.isEmpty else { return false }
    func holds(_ entries: [TranscriptEntry]) -> Bool {
      entries.contains { entry in
        if case let .tool(call) = entry { return runToolCallIds.contains(call.toolCallId) }
        return false
      }
    }
    return holds(entries) || subagents.values.contains { holds($0.entries) }
  }

  public var subagentActivityFingerprint: Int {
    var hasher = Hasher()
    for key in subagents.keys.sorted() {
      guard let bucket = subagents[key] else { continue }
      hasher.combine(key)
      hasher.combine(bucket.entries.count)
      hasher.combine(bucket.isThinking)
      if case let .text(_, markdown) = bucket.entries.last {
        hasher.combine(markdown.utf8.count)
      }
    }
    return hasher.finalize()
  }

  public var duration: TimeInterval? {
    guard let startedAt, let endedAt else { return nil }
    return max(0, endedAt.timeIntervalSince(startedAt))
  }

  public var finalTextIndex: Int? {
    guard let index = responseCandidateIndex else { return nil }
    guard isGenerating, case let .text(id, _) = entries[index], textPhases[id] != .final else { return index }
    return entries[(index + 1)...].contains { !$0.isBlankText } ? nil : index
  }

  var responseCandidateIndex: Int? {
    entries.indices.reversed().first { index in
      let entry = entries[index]
      guard case let .text(id, _) = entry, !entry.isBlankText else { return false }
      return textPhases[id] != .commentary
    }
  }
}
