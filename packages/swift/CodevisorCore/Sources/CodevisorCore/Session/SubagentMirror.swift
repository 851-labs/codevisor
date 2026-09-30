import ACPKit
import Foundation
import Observation
import TranscriptKit

/// A read-only chat controller showing ONE subagent's thread as a
/// conversation of its own: the parent's instructions as the user message,
/// the subagent's prose and tool calls as the assistant turn.
///
/// A subagent has no session. Its thread lives inside the parent turn that
/// spawned it (`AssistantTurn.subagents`, keyed by the spawning tool call), so
/// the mirror re-derives that conversation whenever the parent's transcript
/// changes and the ordinary chat surface renders it unchanged. The mirror
/// never connects, sends, or registers as a chat.
@MainActor
@Observable
public final class SubagentMirror {
  /// Whether the subagent's thread can be shown.
  public enum Availability: Equatable, Sendable {
    /// Not found yet: the parent is loading, or its history is being
    /// searched for the spawning call.
    case loading
    case available
    /// The spawning call isn't in the parent's history (or the search budget
    /// ran out).
    case unavailable
  }

  /// What the mirror knows about its subagent, for titles and accessibility.
  public struct Summary: Equatable, Sendable {
    public var title: String
    public var agentType: String?
    public var isRunning: Bool
    public var status: ToolCallStatus?
  }

  public let parent: SessionController
  public let toolCallId: String
  /// The read-only controller a chat surface renders.
  public let controller: SessionController
  /// Once available, stays available while the parent reloads or re-finds
  /// the call (reconnects swap finished turns back to summaries): the last
  /// projection remains on screen instead of flashing a loading state.
  public private(set) var availability: Availability = .loading
  public private(set) var summary: Summary?

  /// Row identities stay fixed for the mirror's lifetime so updates stream
  /// into the same projected rows.
  @ObservationIgnored private var rowIds: [String: UUID] = [:]
  @ObservationIgnored private var isStarted = false
  /// The parent message that holds the spawning call, once found: hydrated
  /// first when a reconnect summarizes it.
  @ObservationIgnored private var spawningMessageId: UUID?
  /// The thread as read from the parent's settled items, recomputed only when
  /// they change (not on every token the active item streams).
  @ObservationIgnored private var settledThread: (model: ObjectIdentifier, revision: UInt64, thread: Thread)?
  @ObservationIgnored private var requestedDetailItemIds: Set<String> = []
  @ObservationIgnored private weak var searchedParentModel: SessionModel?
  @ObservationIgnored private var isSearching = false
  @ObservationIgnored private var olderHistoryPagesLoaded = 0
  @ObservationIgnored private var visibleViews = 0
  /// When the subagent was first seen finished, for its "Worked for" time
  /// while the spawning turn is still running.
  @ObservationIgnored private var observedFinishAt: Date?
  @ObservationIgnored private let now: () -> Date

  /// Bounds on the search for a spawning call missing from the loaded
  /// transcript (a pane restored after relaunch, or a turn summarized by a
  /// reconnect): summarized turns to hydrate, then older pages to load.
  static let maximumDetailHydrations = 12
  static let maximumOlderHistoryPages = 8

  public init(parent: SessionController, toolCallId: String, now: @escaping () -> Date = Date.init) {
    self.parent = parent
    self.toolCallId = toolCallId
    self.now = now
    controller = SessionController(
      project: parent.project, configCache: parent.configCache, serverClient: parent.serverClient)
    // Subagents run in their chat's harness (a nested agent's row shows it).
    controller.selectedHarnessId = parent.serverSession?.harnessId ?? parent.activeHarnessId
  }

  /// Begins mirroring the parent. Idempotent; mirroring ends when the mirror
  /// is released.
  public func start() {
    guard !isStarted else { return }
    isStarted = true
    observe()
  }

  /// A view showing the mirror appeared or disappeared. The parent streams
  /// at its visible cadence while any of its subagents is on screen, even
  /// when the parent's own transcript is hidden (iOS pushes over it).
  public func viewDidAppear() {
    visibleViews += 1
    parent.transcriptViewDidAppear()
  }

  public func viewDidDisappear() {
    guard visibleViews > 0 else { return }
    visibleViews -= 1
    parent.transcriptViewDidDisappear()
  }

  isolated deinit {
    for _ in 0..<visibleViews { parent.transcriptViewDidDisappear() }
  }

  private func observe() {
    withObservationTracking {
      update()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observe() }
    }
  }

  // MARK: - Update

  /// One piece of the agent's conversation, as read from the parent.
  enum Piece: Equatable {
    /// A message sent to the agent after its spawn (Claude's `SendMessage`).
    case followUp(key: String, text: String, position: Int?)
    /// One entry of the agent's own thread, in the parent item it streamed into.
    case work(TranscriptEntry, position: Int?, messageId: UUID, turn: AssistantTurn)

    var position: Int? {
      switch self {
      case let .followUp(_, _, position), let .work(_, position, _, _): position
      }
    }
  }

  /// The agent's conversation gathered from the parent's items.
  struct Thread: Equatable {
    var spawn: ToolCall?
    var spawnMessageId: UUID?
    var prompt: String?
    var pieces: [Piece] = []
    /// Its spawning (or continuing) call is open in a generating item.
    var isLive = false
    /// Parent items after the spawn still in summary form: their details may
    /// hold messages sent to the agent, or its later work.
    var summarizedItemIds: [String] = []
  }

  /// Re-derives the mirrored conversation from the parent's transcript.
  func update() {
    guard let parentModel = parent.model, !parent.isLoadingInitialHistory else {
      if availability != .available { setAvailability(.loading) }
      return
    }
    // A reconnected parent reloads summarized turns: the search starts over.
    if searchedParentModel !== parentModel {
      searchedParentModel = parentModel
      requestedDetailItemIds.removeAll()
      olderHistoryPagesLoaded = 0
    }
    var thread = settledThread(of: parentModel)
    if case let .assistant(message)? = parent.activeItem {
      Self.collect(toolCallId, from: message, isActive: true, into: &thread)
    }
    guard let spawn = thread.spawn else {
      searchForSpawningCall()
      return
    }
    spawningMessageId = thread.spawnMessageId
    setAvailability(.available)
    loadSummarizedItems(thread.summarizedItemIds)

    let isRunning = thread.isLive || parent.runningSubagentToolCallIds.contains(toolCallId)
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
      status: spawn.status
    )
    if summary != next { summary = next }
  }

  private func settledThread(of model: SessionModel) -> Thread {
    let key = (ObjectIdentifier(model), model.transcriptProjectionRevision)
    if let cached = settledThread, cached.model == key.0, cached.revision == key.1 { return cached.thread }
    var thread = Thread()
    for item in model.settledConversation {
      guard case let .assistant(message) = item else { continue }
      Self.collect(toolCallId, from: message, isActive: false, into: &thread)
    }
    settledThread = (key.0, key.1, thread)
    return thread
  }

  /// Adds one parent item's part of the agent's conversation: its spawn,
  /// messages sent to it, and the entries it streamed there.
  static func collect(_ toolCallId: String, from message: AssistantMessage, isActive: Bool, into thread: inout Thread) {
    let turn = message.turn
    let call = spawningCall(toolCallId, in: turn)
    // The spawn carries the agent's input; an item it only continues in holds
    // a bare placeholder call for its thread.
    if thread.spawn == nil, let call, call.rawInput != nil {
      thread.spawn = call
      thread.spawnMessageId = message.id
      thread.prompt = call.rawInput?["prompt"]?.stringValue
    }
    guard thread.spawn != nil else { return }
    if turn.hasDeferredWorkedDetails, !turn.hasHydratedWorkedDetails, let itemId = turn.deferredDetailItemId {
      thread.summarizedItemIds.append(itemId)
    }
    // Messages sent to the agent name the same task as its spawn.
    let taskId = thread.spawn?.subagentTaskId
    for case let .tool(sent) in turn.entries
    where taskId != nil && sent.subagentTaskId == taskId && sent.toolCallId != toolCallId {
      guard let text = sent.rawInput?["message"]?.stringValue, !text.isEmpty else { continue }
      thread.pieces.append(
        .followUp(
          key: sent.toolCallId, text: text,
          position: turn.entryPositions["tool:\(sent.toolCallId)"] ?? sent.statePosition))
    }
    // An entry without its own position stays behind the one before it, as
    // the parent's transcript orders entries.
    var anchor: Int?
    for entry in turn.subagents[toolCallId]?.entries ?? [] {
      anchor = turn.entryPositions[entry.id] ?? anchor
      thread.pieces.append(.work(entry, position: anchor, messageId: message.id, turn: turn))
    }
    if isActive, turn.isGenerating, let call, !call.isSettled { thread.isLive = true }
  }

  /// The agent's conversation as chat items: its instructions and each
  /// follow-up as user messages, the work answering each as an assistant
  /// turn, the latest live while the agent runs.
  ///
  /// A follow-up's answer streams under the agent's spawning call, into
  /// whichever parent item the server routes it to — possibly the one it
  /// first ran in — so the thread is ordered by the server's event positions
  /// and split into runs at each follow-up. Without positions (older data)
  /// it keeps the parent's item order.
  private func conversation(
    of thread: Thread, isRunning: Bool
  ) -> (settled: [ConversationItem], active: ConversationItem?) {
    var pieces = thread.pieces
    if pieces.allSatisfy({ $0.position != nil }) {
      pieces = pieces.enumerated().sorted { lhs, rhs in
        let (l, r) = (lhs.element.position ?? 0, rhs.element.position ?? 0)
        return l == r ? lhs.offset < rhs.offset : l < r
      }.map(\.element)
    }

    struct Run {
      var entries: [TranscriptEntry] = []
      var first: AssistantTurn?
      var last: AssistantTurn?
    }
    enum Step {
      case instruction(key: String, text: String)
      case run(Run)
    }
    var steps: [Step] = []
    if let prompt = thread.prompt, !prompt.isEmpty { steps.append(.instruction(key: "prompt", text: prompt)) }
    var current = Run()
    func closeRun() {
      if !current.entries.isEmpty { steps.append(.run(current)) }
      current = Run()
    }
    for piece in pieces {
      switch piece {
      case let .followUp(key, text, _):
        closeRun()
        steps.append(.instruction(key: "follow-up:\(key)", text: text))
      case let .work(entry, _, _, turn):
        current.entries.append(entry)
        current.first = current.first ?? turn
        current.last = turn
      }
    }
    closeRun()

    var items: [ConversationItem] = []
    var runIndex = 0
    for (index, step) in steps.enumerated() {
      switch step {
      case let .instruction(key, text):
        items.append(.user(UserMessage(id: rowId(key), text: text)))
      case let .run(run):
        let isLatest = index == steps.count - 1
        let live = isLatest && isRunning
        let last = run.last ?? AssistantTurn()
        // A subagent's own timing isn't reported: each run is bounded by the
        // parent items it streamed into, the latest ending with them or when
        // it was seen done.
        let endedAt =
          live
          ? nil : !isLatest ? last.endedAt : last.isGenerating ? observedFinishAt : last.endedAt ?? observedFinishAt
        items.append(
          .assistant(
            AssistantMessage(
              id: rowId("run:\(runIndex)"),
              turn: Self.mirrorTurn(
                of: SubagentTranscript(
                  entries: run.entries, isThinking: last.subagents[toolCallId]?.isThinking ?? false),
                isRunning: live, startedAt: run.first?.startedAt, endedAt: endedAt, subagents: last.subagents))))
        runIndex += 1
      }
    }
    // Messaged but not yet answering: the agent is working on it.
    if isRunning, case .user? = items.last {
      items.append(
        .assistant(
          AssistantMessage(
            id: rowId("run:\(runIndex)"),
            turn: AssistantTurn(isGenerating: true, isThinking: true))))
    }
    guard case .assistant? = items.last else { return (items, nil) }
    return (Array(items.dropLast()), items.last)
  }

  private func rowId(_ key: String) -> UUID {
    if let id = rowIds[key] { return id }
    let id = UUID()
    rowIds[key] = id
    return id
  }

  /// The subagent's thread as a standalone assistant turn. Subagent threads
  /// carry no message phases, so they're assigned the way a live chat reads:
  /// while running every span is commentary (no answer yet); once finished,
  /// only a span ending the thread is the answer.
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
      // Flat by design: a nested subagent's row resolves by lookup.
      subagents: subagents,
      textPhases: phases
    )
  }

  /// The call that spawned agent `toolCallId` in `controller`'s chat — the
  /// one with its input. Work an agent does after a follow-up streams into a
  /// later item under a bare placeholder call carrying only its id.
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

  /// The subagent's short description ("Map the chat UI").
  public static func title(of call: ToolCall) -> String {
    if let description = call.rawInput?["description"]?.stringValue,
      !description.trimmingCharacters(in: .whitespaces).isEmpty
    {
      return description
    }
    let title = call.displayTitle
    return title.hasPrefix("Agent: ") ? String(title.dropFirst("Agent: ".count)) : title
  }

  // MARK: - Finding the spawning call

  /// Subagents are spawned from the main thread or (nested) from another
  /// subagent's thread; both live in the turn.
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

  /// The call isn't in the loaded transcript. Turns from history arrive as
  /// summaries with their tool calls deferred, so hydrate those first — the
  /// turn it was last seen in, then newest to oldest — and only then page in
  /// older history. Each step re-runs `update()`; a bounded search that
  /// finds nothing makes the agent unavailable.
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
        // Only a page that added history counts against the budget; a load
        // already in flight elsewhere finishes and re-runs this observer.
        if await parent.loadOlderHistory() > 0 { self?.olderHistoryPagesLoaded += 1 }
      }
    } else if availability != .available {
      setAvailability(parent.isLoadingOlderHistory ? .loading : .unavailable)
    }
  }

  /// Chats loaded from history summarize each finished item. Load the ones
  /// after the spawn (bounded, one at a time) so follow-ups and later work
  /// appear — the agent stays on screen meanwhile.
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
    // A history load keeps the trailing turn active, so a turn that finished
    // and came back summarized lives there, not in the settled items.
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

  /// The mirror's model shares the parent's transport so paged tool output
  /// loads; it never opens an event stream of its own. A reconnected parent
  /// gets a new model and transport, and the mirror follows it.
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
  /// Publishes a mirror's synthetic conversation. The settled prompt row
  /// changes only when it actually differs, so streaming re-projects just the
  /// active row.
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
