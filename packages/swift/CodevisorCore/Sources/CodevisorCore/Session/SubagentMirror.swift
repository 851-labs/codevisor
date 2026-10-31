import ACPKit
import Foundation
import Observation
import TranscriptKit

@MainActor
@Observable
public final class SubagentMirror {
  public enum Availability: Equatable, Sendable {
    case loading
    case available
    case unavailable
  }

  public struct Summary: Equatable, Sendable {
    public var title: String
    public var agentType: String?
    public var isRunning: Bool
    public var status: ToolCallStatus?
  }

  public let parent: SessionController
  public let toolCallId: String
  public let controller: SessionController
  public private(set) var availability: Availability = .loading
  public private(set) var summary: Summary?

  @ObservationIgnored private var rowIds: [String: UUID] = [:]
  @ObservationIgnored private var isStarted = false
  @ObservationIgnored private var spawningMessageId: UUID?
  @ObservationIgnored private var settledThread:
    (key: SettledKey, agent: SubagentThreadCollector.Agent, thread: SubagentThreadCollector.Thread)?
  @ObservationIgnored private var requestedDetailItemIds: Set<String> = []
  @ObservationIgnored private weak var searchedParentModel: SessionModel?
  @ObservationIgnored private var isSearching = false
  @ObservationIgnored private var olderHistoryPagesLoaded = 0
  @ObservationIgnored private var visibleViews = 0
  @ObservationIgnored private var observedFinishAt: Date?
  @ObservationIgnored private let now: () -> Date

  static let maximumDetailHydrations = 12
  static let maximumOlderHistoryPages = 8

  public init(parent: SessionController, toolCallId: String, now: @escaping () -> Date = Date.init) {
    self.parent = parent
    self.toolCallId = toolCallId
    self.now = now
    controller = SessionController(
      project: parent.project, configCache: parent.configCache, serverClient: parent.serverClient)
    controller.fileSource = parent
    controller.selectedHarnessId = parent.serverSession?.harnessId ?? parent.activeHarnessId
  }

  public func start() {
    guard !isStarted else { return }
    isStarted = true
    observe()
  }

  public func viewDidAppear() {
    visibleViews += 1
    parent.presentationClock.viewDidAppear()
  }

  public func viewDidDisappear() {
    guard visibleViews > 0 else { return }
    visibleViews -= 1
    parent.presentationClock.viewDidDisappear()
  }

  isolated deinit {
    for _ in 0..<visibleViews { parent.presentationClock.viewDidDisappear() }
  }

  private func observe() {
    withObservationTracking {
      update()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observe() }
    }
  }

  func update() {
    guard let parentModel = parent.model, !parent.isLoadingInitialHistory else {
      if availability != .available { setAvailability(.loading) }
      return
    }
    if searchedParentModel !== parentModel {
      searchedParentModel = parentModel
      requestedDetailItemIds.removeAll()
      olderHistoryPagesLoaded = 0
    }
    let activeMessage: AssistantMessage? =
      if case let .assistant(message)? = parent.activeItem { message } else { nil }
    let activeTaskId = activeMessage.flatMap { Self.spawningCall(toolCallId, in: $0.turn)?.subagentTaskId }
    let fromSettled = settledThread(of: parentModel, activeTaskId: activeTaskId)
    var thread = fromSettled.thread
    if let activeMessage {
      SubagentThreadCollector.collect(fromSettled.agent, from: activeMessage, isActive: true, into: &thread)
    }
    guard let spawn = thread.spawn else {
      if thread.isStarting {
        if availability != .available { setAvailability(.loading) }
      } else {
        searchForSpawningCall()
      }
      return
    }
    spawningMessageId = thread.spawnMessageId
    setAvailability(.available)
    if thread.isMissingEarlierRuns {
      searchForSpawningCall()
    } else {
      loadSummarizedItems(thread.summarizedItemIds)
    }

    let runningIds = parent.runningSubagentToolCallIds
    let isRunning =
      thread.isLive || runningIds.contains(toolCallId) || thread.runIds.contains(where: runningIds.contains)
    if isRunning {
      observedFinishAt = nil
    } else if observedFinishAt == nil {
      observedFinishAt = now()
    }
    let (settled, active) = conversation(of: thread, isRunning: isRunning)
    mirrorModel(following: parentModel).applyMirror(settled: settled, active: active)

    let next = Summary(
      title: Self.title(of: spawn),
      agentType: spawn.rawInput?["subagent_type"]?.stringValue,
      isRunning: isRunning,
      status: (thread.latestRun ?? spawn).status
    )
    if summary != next { summary = next }
  }

  private func settledThread(
    of model: SessionModel, activeTaskId: String?
  ) -> (agent: SubagentThreadCollector.Agent, thread: SubagentThreadCollector.Thread) {
    let key = SettledKey(
      model: ObjectIdentifier(model), revision: model.transcriptProjectionRevision, activeTaskId: activeTaskId)
    if let cached = settledThread, cached.key == key { return (cached.agent, cached.thread) }
    let settledTaskId = model.settledConversation.lazy.compactMap { item -> String? in
      guard case let .assistant(message) = item else { return nil }
      return Self.spawningCall(self.toolCallId, in: message.turn)?.subagentTaskId
    }.first
    let agent = SubagentThreadCollector.Agent(toolCallId: toolCallId, taskId: activeTaskId ?? settledTaskId)
    var thread = SubagentThreadCollector.Thread()
    for item in model.settledConversation {
      guard case let .assistant(message) = item else { continue }
      SubagentThreadCollector.collect(agent, from: message, isActive: false, into: &thread)
    }
    settledThread = (key, agent, thread)
    return (agent, thread)
  }

  private struct SettledKey: Equatable {
    var model: ObjectIdentifier
    var revision: UInt64
    var activeTaskId: String?
  }

  private func conversation(
    of thread: SubagentThreadCollector.Thread, isRunning: Bool
  ) -> (settled: [ConversationItem], active: ConversationItem?) {
    let steps = SubagentConversationSequence.steps(of: thread)
    let items = conversationItems(from: steps, isRunning: isRunning)
    guard case .assistant? = items.last else { return (items, nil) }
    return (Array(items.dropLast()), items.last)
  }

  private func conversationItems(
    from steps: [SubagentConversationSequence.Step], isRunning: Bool
  ) -> [ConversationItem] {
    var items: [ConversationItem] = []
    var runIndex = 0
    for (index, step) in steps.enumerated() {
      switch step {
      case let .instruction(key, text?):
        items.append(.user(UserMessage(id: rowId(key), text: text)))
      case .instruction:
        continue
      case let .run(run):
        let isLatest = index == steps.count - 1
        items.append(assistantRun(run, isLatest: isLatest, runIndex: runIndex, isRunning: isRunning))
        runIndex += 1
      }
    }
    appendPendingRun(to: &items, steps: steps, runIndex: runIndex, isRunning: isRunning)
    return items
  }

  private func assistantRun(
    _ run: SubagentConversationSequence.Run, isLatest: Bool, runIndex: Int, isRunning: Bool
  ) -> ConversationItem {
    let live = isLatest && isRunning
    let last = run.last ?? AssistantTurn()
    let endedAt = runEndedAt(last, isLatest: isLatest, live: live)
    return
      (.assistant(
        AssistantMessage(
          id: rowId("run:\(runIndex)"),
          turn: Self.mirrorTurn(
            of: SubagentTranscript(
              entries: run.entries, isThinking: last.subagents[run.lastRunId ?? toolCallId]?.isThinking ?? false),
            isRunning: live, startedAt: run.first?.startedAt, endedAt: endedAt, subagents: last.subagents))))
  }

  private func runEndedAt(_ last: AssistantTurn, isLatest: Bool, live: Bool) -> Date? {
    if live { return nil }
    if !isLatest { return last.endedAt }
    if last.isGenerating { return observedFinishAt }
    return last.endedAt ?? observedFinishAt
  }

  private func appendPendingRun(
    to items: inout [ConversationItem], steps: [SubagentConversationSequence.Step], runIndex: Int, isRunning: Bool
  ) {
    let awaitsRun = steps.last.map { if case .instruction = $0 { true } else { false } } ?? true
    if isRunning, awaitsRun {
      items.append(
        .assistant(
          AssistantMessage(
            id: rowId("run:\(runIndex)"),
            turn: AssistantTurn(isGenerating: true, isThinking: true))))
    }
  }

  private func rowId(_ key: String) -> UUID {
    if let id = rowIds[key] { return id }
    let id = UUID()
    rowIds[key] = id
    return id
  }

  static func mirrorTurn(
    of bucket: SubagentTranscript,
    isRunning: Bool,
    startedAt: Date?,
    endedAt: Date?,
    subagents: [String: SubagentTranscript]
  ) -> AssistantTurn {
    var phases: [String: MessagePhase] = [:]
    for (index, entry) in bucket.entries.enumerated() {
      guard case let .text(id, _) = entry else { continue }
      phases[id] = !isRunning && index == bucket.entries.count - 1 ? .final : .commentary
    }
    return AssistantTurn(
      entries: bucket.entries,
      isGenerating: isRunning,
      isThinking: isRunning && bucket.isThinking,
      stopReason: isRunning ? nil : .endTurn,
      startedAt: startedAt,
      endedAt: endedAt,
      subagents: subagents,
      textPhases: phases
    )
  }

  public static func spawn(of toolCallId: String, in controller: SessionController) -> ToolCall? {
    let items = controller.activeItem.map { [$0] } ?? []
    for item in items + controller.settledConversation.reversed() {
      guard case let .assistant(message) = item,
        let call = spawningCall(toolCallId, in: message.turn), call.rawInput != nil
      else { continue }
      return call
    }
    return nil
  }

  public static func title(of call: ToolCall) -> String {
    call.agentName
  }

  static func spawningCall(_ toolCallId: String, in turn: AssistantTurn) -> ToolCall? {
    if let call = turn.entries.lazy.compactMap(\.toolCall).first(where: { $0.toolCallId == toolCallId }) {
      return call
    }
    for bucket in turn.subagents.values {
      if let call = bucket.entries.lazy.compactMap(\.toolCall).first(where: { $0.toolCallId == toolCallId }) {
        return call
      }
    }
    return nil
  }

  private func searchForSpawningCall() {
    guard !isSearching else { return }
    if let itemId = nextSummarizedTurnToHydrate() {
      requestedDetailItemIds.insert(itemId)
      search { parent in
        _ = await parent.loadTranscriptDetails(itemId)
      }
    } else if parent.hasOlderHistory, !parent.isLoadingOlderHistory,
      olderHistoryPagesLoaded < Self.maximumOlderHistoryPages
    {
      search { [weak self] parent in
        if await parent.loadOlderHistory() > 0 { self?.olderHistoryPagesLoaded += 1 }
      }
    } else if availability != .available {
      setAvailability(parent.isLoadingOlderHistory ? .loading : .unavailable)
    }
  }

  private func loadSummarizedItems(_ itemIds: [String]) {
    guard !isSearching, requestedDetailItemIds.count < Self.maximumDetailHydrations,
      let itemId = itemIds.first(where: { !requestedDetailItemIds.contains($0) })
    else { return }
    requestedDetailItemIds.insert(itemId)
    search { parent in
      _ = await parent.loadTranscriptDetails(itemId)
    }
  }

  private func search(_ step: @escaping @MainActor (SessionController) async -> Void) {
    isSearching = true
    if availability != .available { setAvailability(.loading) }
    Task { [weak self, parent] in
      await step(parent)
      guard let self else { return }
      isSearching = false
      update()
    }
  }

  private func nextSummarizedTurnToHydrate() -> String? {
    guard requestedDetailItemIds.count < Self.maximumDetailHydrations else { return nil }
    let active = parent.activeItem.map { [$0] } ?? []
    let newestFirst = active + parent.settledConversation.reversed()
    let lastSeen = newestFirst.filter { $0.id == spawningMessageId }
    for item in lastSeen + newestFirst.filter({ $0.id != spawningMessageId }) {
      guard case let .assistant(message) = item, message.turn.hasDeferredWorkedDetails,
        let itemId = message.turn.deferredDetailItemId, !requestedDetailItemIds.contains(itemId)
      else { continue }
      return itemId
    }
    return nil
  }

  private func setAvailability(_ next: Availability) {
    if availability != next { availability = next }
  }

  @ObservationIgnored private weak var followedParentModel: SessionModel?

  private func mirrorModel(following parentModel: SessionModel) -> SessionModel {
    if let model = controller.model, followedParentModel === parentModel { return model }
    let model = SessionModel(serverTransport: parentModel.transport, sessionId: "subagent:\(toolCallId)")
    followedParentModel = parentModel
    controller.model = model
    return model
  }
}

extension SessionModel {
  func applyMirror(settled: [ConversationItem], active: ConversationItem?) {
    if settledConversation != settled {
      settledConversation = settled
      rebuildSettledIndex()
    }
    if activeItem != active { activeItem = active }
    if hasActiveItem != (active != nil) { hasActiveItem = active != nil }
  }
}

extension TranscriptEntry {
  fileprivate var toolCall: ToolCall? {
    if case let .tool(call) = self { return call }
    return nil
  }
}
