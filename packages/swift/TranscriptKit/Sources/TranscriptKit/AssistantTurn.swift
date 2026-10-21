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
  public var autoResume: SessionAutoResume? = nil
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
  public var setupRequests: [TranscriptSetupRequest] = []
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

  var isSplitByPlan: Bool {
    planBoundary != nil || planDocument?.isEmpty == false
  }

  public func defersWorkedSection(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard hasDeferredWorkedDetails else { return false }
    switch kind {
    case .planning: return true
    case .implementation: return planResumedAt != nil
    }
  }

  public func isWorkedSectionLive(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard isGenerating, !finalTextIsAsserted else { return false }
    switch kind {
    case .planning: return !isSplitByPlan
    case .implementation: return true
    }
  }

  public func workedSectionStart(_ kind: TranscriptWorkedSectionKind) -> Date? {
    switch kind {
    case .planning: startedAt
    case .implementation: planResumedAt ?? planProposedAt
    }
  }

  public func workedSectionDuration(_ kind: TranscriptWorkedSectionKind) -> TimeInterval? {
    let end: Date? =
      switch kind {
      case .planning:
        !isSplitByPlan
          ? endedAt
          : planProposedAt ?? (planResumedAt == nil && workedItemsAfterPlan.isEmpty ? endedAt : nil)
      case .implementation: endedAt
      }
    guard let start = workedSectionStart(kind), let end else { return nil }
    return max(0, end.timeIntervalSince(start))
  }

  public func workedSectionTitle(_ kind: TranscriptWorkedSectionKind, now: Date) -> String {
    if workedSectionTicks(kind) {
      let start = workedSectionStart(kind) ?? now
      return "Working for \(Self.formatWorkedDuration(now.timeIntervalSince(start)))"
    }
    guard let duration = workedSectionDuration(kind) else {
      return isSplitByPlan ? "Worked" : "Worked for a moment"
    }
    guard duration >= 1 else { return "Worked for a moment" }
    return "Worked for \(Self.formatWorkedDuration(duration))"
  }

  public func workedSectionTicks(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard isGenerating else { return false }
    switch kind {
    case .planning: return !isSplitByPlan
    case .implementation: return true
    }
  }

  public func showsLiveWorkedHeader(_ kind: TranscriptWorkedSectionKind) -> Bool {
    isWorkedSectionLive(kind) && (isThinking || hasProviderContent)
  }

  public func showsWorkedHeaderWithoutWork(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard hasProviderContent || (isGenerating && isThinking) else { return false }
    switch kind {
    case .planning: return !isSplitByPlan
    case .implementation: return planResumedAt != nil
    }
  }

  public var hasProviderContent: Bool {
    entries.contains { entry in
      if case .contextCompaction = entry { return false }
      return !entry.isBlankText
    }
  }

  public func showsWorkedThinkingLine(_ kind: TranscriptWorkedSectionKind) -> Bool {
    isGenerating && isThinking && showsLiveWorkedHeader(kind)
  }

  public func workedSectionElapsed(_ kind: TranscriptWorkedSectionKind, now: Date) -> String {
    Self.formatWorkedDuration(now.timeIntervalSince(workedSectionStart(kind) ?? now))
  }

  public static func formatWorkedDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.down)))
    return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
  }

  public func isUnstartedSubagent(_ call: ToolCall) -> Bool {
    call.kind == .agent && call.rawInput == nil && subagents[call.toolCallId]?.entries.isEmpty != false
  }

  public var isStartingSubagent: Bool {
    isGenerating && toolCalls.contains { !$0.isSettled && isUnstartedSubagent($0) }
  }

  public var awaitedAgentCalls: [ToolCall] {
    guard isGenerating else { return [] }
    var awaited: [ToolCall] = []
    for entry in entries.reversed() {
      if case .contextCompaction = entry { continue }
      if entry.isBlankText { continue }
      guard case let .tool(call) = entry, call.kind == .agent else { break }
      if !call.isSettled, !isUnstartedSubagent(call) { awaited.append(call) }
    }
    return awaited.reversed()
  }

  public var workedItems: [WorkedItem] {
    groupedItems(workedEntries)
  }

  public var workedItemsBeforePlan: [WorkedItem] {
    guard let boundary = planBoundary else { return workedItems }
    return groupedItems(workedSlice(0..<min(boundary, entries.count)))
  }

  public var workedItemsAfterPlan: [WorkedItem] {
    guard let boundary = planBoundary else { return [] }
    return groupedItems(workedSlice(min(boundary, entries.count)..<entries.count))
  }

  private func workedSlice(_ range: Range<Int>) -> [TranscriptEntry] {
    let finalIndex = finalTextIndex
    return range.compactMap { index in
      if index == finalIndex { return nil }
      if case let .tool(call) = entries[index], call.kind == .imageGeneration { return nil }
      return entries[index]
    }
  }

  private func groupedItems(_ source: [TranscriptEntry]) -> [WorkedItem] {
    var items: [WorkedItem] = []
    var group: [ToolCall] = []
    var groupHasUnsettledCall = false
    var agents: [ToolCall] = []

    func flushAgents() {
      guard let first = agents.first else { return }
      items.append(.subagents(id: first.toolCallId, calls: agents))
      agents = []
    }

    func flushGroup() {
      guard !group.isEmpty else { return }
      items.append(
        .toolGroup(
          ToolCallGroup(
            calls: group,
            hasUnsettledCall: groupHasUnsettledCall
          )))
      group = []
      groupHasUnsettledCall = false
    }

    func flush() {
      flushAgents()
      flushGroup()
    }

    for entry in source {
      switch entry {
      case let .text(id, markdown):
        guard !entry.isBlankText else { continue }
        flush()
        items.append(.text(id: id, markdown: markdown))
      case let .tool(call) where isUnstartedSubagent(call):
        continue
      case let .tool(call) where call.kind == .agent || subagents[call.toolCallId] != nil:
        flushGroup()
        agents.append(call)
      case let .tool(call):
        flushAgents()
        if callsAfterReasoning.contains(call.toolCallId) { flushGroup() }
        group.append(call)
        groupHasUnsettledCall = groupHasUnsettledCall || !call.isSettled
      case .contextCompaction:
        continue
      }
    }
    flush()
    return items
  }

  public var generatedImageActivity: [ToolCall] {
    toolCalls.filter { $0.kind == .imageGeneration && $0.generatedImageAttachment == nil }
  }

  mutating func addSetupRequest(_ request: TranscriptSetupRequest) {
    guard !setupRequests.contains(where: { $0.id == request.id }) else { return }
    setupRequests.append(request)
  }

  mutating func upsertSetupRequest(_ request: TranscriptSetupRequest) {
    guard let index = setupRequests.firstIndex(where: { $0.id == request.id }) else {
      setupRequests.append(request)
      return
    }
    setupRequests[index].state = request.state
  }

  mutating func receiveGeneratedImage(_ call: ToolCall) {
    guard call.parentToolCallId == nil, let image = call.generatedImageAttachment,
      !attachments.contains(where: { $0.fileId == image.fileId })
    else { return }
    attachments.append(image)
  }
}
