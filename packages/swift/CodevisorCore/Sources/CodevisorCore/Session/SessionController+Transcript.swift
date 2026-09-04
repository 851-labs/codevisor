import Foundation
import ACPKit

/// Opaque registration for one native transcript surface's display clock.
/// The controller elects the fastest visible registration as the session's
/// presentation driver.
public struct TranscriptFrameDriverToken: Hashable, Sendable {
  fileprivate let rawValue = UUID()
}

struct TranscriptFrameDriver {
  let maximumFramesPerSecond: Int
  let requestFrame: @MainActor () -> Void
}

extension SessionController {
  // MARK: - Derived state

  public var conversation: [ConversationItem] { model?.conversation ?? [] }
  /// Split accessors for the transcript: bodies that iterate rows read the
  /// settled list; ONLY the dedicated active-row child view reads
  /// `activeItem`, so token flushes invalidate one bubble instead of the
  /// whole transcript. `hasActiveItem` is boundary-guarded for containers
  /// that need existence without per-flush invalidation.
  public var settledConversation: [ConversationItem] { model?.settledConversation ?? [] }
  public var activeItem: ConversationItem? { model?.activeItem }
  public var activeItemRevision: UInt64 { model?.activeItemRevision ?? 0 }
  public var hasActiveItem: Bool { model?.hasActiveItem ?? false }
  /// The active slot remains mounted after completion for stable rendering.
  /// Expose its canonical identity only once it represents a finished turn.
  public var activeFinishedResponseItemId: UUID? {
    model?.activeFinishedResponseItemId
  }
  public var transcriptProjectionKey: TranscriptProjectionKey {
    TranscriptProjectionKey(
      // Controller lifetime, rather than the durable chat id: a cache
      // entry from an evicted controller must never match a freshly
      // replayed controller whose counters restarted at zero.
      sessionID: transcriptProjectionID,
      controllerRevision: transcriptProjectionRevision,
      modelRevision: model?.transcriptProjectionRevision ?? 0
    )
  }

  /// Captured on `MainActor`, then consumed by `TranscriptRowProjectionCache`
  /// on its own actor. Array/string storage is immutable copy-on-write.
  public var transcriptProjectionInput: TranscriptProjectionInput {
    let projectionStatus: TranscriptProjectionInput.ConnectionStatus
    switch status {
    case .idle:
      projectionStatus = .idle
    case let .connecting(message):
      projectionStatus = .connecting(message)
    case let .failed(message):
      projectionStatus = .failed(message)
    }
    return TranscriptProjectionInput(
      settledConversation: settledConversation,
      pendingUserMessage: pendingUserMessage,
      activeItem: activeItem,
      setupPhases: setupPhases,
      waitingBackgroundTaskDescription: waitingBackgroundTaskDescription,
      waitingHarnessUpdateName: waitingHarnessUpdateName,
      isLoadingInitialHistory: isLoadingInitialHistory,
      serverWaitMessage: serverWaitMessage,
      sessionErrorMessage: sessionErrorMessage,
      status: projectionStatus
    )
  }
  public var hasOlderHistory: Bool { model?.hasOlderHistory ?? false }
  public var isLoadingOlderHistory: Bool { model?.isLoadingOlderHistory ?? false }
  public var queuedPrompts: [ServerPromptQueueItem] { model?.queuedPrompts ?? [] }
  public var availableCommands: [AvailableCommand] { model?.availableCommands ?? [] }
  public var isConnected: Bool { model != nil }
  /// Whether the harness can still be chosen: only a draft that hasn't sent
  /// anything yet. An empty conversation alone isn't enough — during the
  /// new-chat → session handoff the promoted controller is still connecting
  /// and its conversation is momentarily empty, which made the session
  /// composer's inline picker flash in briefly. The pending/connecting/
  /// session checks keep it hidden through that window.
  public var canChooseHarness: Bool {
    // Deliberately NOT `conversation.isEmpty`: that allocates the merged
    // array and registers Observation on `activeItem`, re-evaluating the
    // composer's picker on every token flush. These two reads are
    // boundary-guarded and allocation-free.
    settledConversation.isEmpty
      && !hasActiveItem
      && pendingUserMessage == nil
      && !isConnecting
      && serverSession?.hasAgentSession != true
      && resumeAgentSessionId?.isEmpty != false
  }

  /// Transcript-view lifecycle, forwarded to the model to tune its stream
  /// flush cadence. Reference-counted: a session can be visible in several
  /// windows or splits at once.
  public func transcriptViewDidAppear() {
    visibleTranscriptViews += 1
    model?.viewDidAppear()
  }

  public func transcriptViewDidDisappear() {
    guard visibleTranscriptViews > 0 else { return }
    visibleTranscriptViews -= 1
    model?.viewDidDisappear()
  }

  /// Registers a visible native surface. `requestFrame` must merely arm its
  /// paused display link; all transcript work happens when that link fires.
  public func registerTranscriptFrameDriver(
    maximumFramesPerSecond: Int,
    requestFrame: @escaping @MainActor () -> Void
  ) -> TranscriptFrameDriverToken {
    let token = TranscriptFrameDriverToken()
    transcriptFrameDrivers[token] = TranscriptFrameDriver(
      maximumFramesPerSecond: max(1, maximumFramesPerSecond),
      requestFrame: requestFrame
    )
    electTranscriptFrameDriver()
    if transcriptPresentationFramePending {
      requestTranscriptPresentationFrame()
    } else {
      model?.preferPresentationFrameIfPending()
    }
    return token
  }

  public func unregisterTranscriptFrameDriver(_ token: TranscriptFrameDriverToken) {
    let wasElected = electedTranscriptFrameDriver == token
    transcriptFrameDrivers.removeValue(forKey: token)
    if wasElected {
      electedTranscriptFrameDriver = nil
      electTranscriptFrameDriver()
    }
    if wasElected, transcriptPresentationFramePending {
      requestTranscriptPresentationFrame()
    }
    if wasElected {
      model?.reschedulePendingEventsForCurrentVisibility()
    }
  }

  /// Called by a registered native display link. Non-elected callbacks are
  /// ignored so two windows on unrelated display clocks cannot double-commit
  /// one session inside a single physical frame.
  public func transcriptPresentationFrameDidFire(_ token: TranscriptFrameDriverToken) {
    guard token == electedTranscriptFrameDriver,
      transcriptFrameDrivers[token] != nil,
      transcriptPresentationFramePending
    else { return }
    transcriptFallbackFrameTask?.cancel()
    transcriptFallbackFrameTask = nil
    transcriptPresentationFramePending = false
    model?.flushPendingEvents()
    transcriptPresentationFrameRevision &+= 1
  }

  /// Arms the elected display link. Projection workers also call this after
  /// preparing a new immutable row snapshot, so publication is gated by the
  /// same clock as ACP event application.
  @discardableResult
  public func requestTranscriptPresentationFrame() -> Bool {
    transcriptPresentationFramePending = true
    electTranscriptFrameDriver()
    if let electedTranscriptFrameDriver,
      let driver = transcriptFrameDrivers[electedTranscriptFrameDriver]
    {
      transcriptFallbackFrameTask?.cancel()
      transcriptFallbackFrameTask = nil
      driver.requestFrame()
      return true
    }

    // A surface can become observable just before AppKit/UIKit attaches it
    // to a window. Preserve progress during that short gap without making
    // the ordinary visible path timer-driven.
    guard transcriptFallbackFrameTask == nil else { return true }
    transcriptFallbackFrameTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(16))
      guard !Task.isCancelled, let self,
        self.transcriptPresentationFramePending
      else { return }
      self.transcriptFallbackFrameTask = nil
      self.transcriptPresentationFramePending = false
      self.model?.flushPendingEvents()
      self.transcriptPresentationFrameRevision &+= 1
    }
    return true
  }

  private func electTranscriptFrameDriver() {
    if let electedTranscriptFrameDriver,
      let elected = transcriptFrameDrivers[electedTranscriptFrameDriver],
      transcriptFrameDrivers.values.allSatisfy({
        $0.maximumFramesPerSecond <= elected.maximumFramesPerSecond
      })
    {
      return
    }
    electedTranscriptFrameDriver =
      transcriptFrameDrivers.max {
        $0.value.maximumFramesPerSecond < $1.value.maximumFramesPerSecond
      }?.key
  }
  public var modeState: SessionModeState? {
    if let live = model?.modeState { return live }
    guard let selectedHarnessId, var state = modeStateByHarness[selectedHarnessId] else { return nil }
    if let pendingModeId { state.currentModeId = pendingModeId }
    return state
  }
  public var errorMessage: String? { model?.errorMessage }
  /// Session-level failures only. A runtime failure that already lives on
  /// the active assistant turn must not also render as a detached banner.
  public var sessionErrorMessage: String? {
    guard let error = model?.errorMessage else { return nil }
    if case let .assistant(message)? = model?.activeItem,
      message.turn.stopDetail == error
    {
      return nil
    }
    return error
  }
  public var errorRequiresHarnessAuthentication: Bool {
    model?.errorRequiresHarnessAuthentication == true
  }
  /* Usage state only feeds the temporarily disabled usage gauge and popover.
  public var usage: SessionUsage? { model?.usage }
  public var usageLimits: ServerHarnessUsageLimits? { model?.usageLimits }
  public var isLoadingUsageLimits: Bool { model?.isLoadingUsageLimits == true }
  public var usageLimitsError: String? { model?.usageLimitsError }

  public func loadUsageLimits(force: Bool = false) async {
      await model?.loadUsageLimits(force: force)
  }
  */

  @discardableResult
  public func loadOlderHistory() async -> Int {
    await model?.loadOlderHistory() ?? 0
  }

  @discardableResult
  public func loadTranscriptDetails(_ itemId: String) async -> Bool {
    await model?.loadTranscriptDetails(itemId: itemId) ?? false
  }

  /// The harness this chat is (or will be) running on: the connected
  /// agent's harness once a session exists, the picker selection before.
  public var activeHarnessId: String? { connectedHarnessId ?? selectedHarnessId }

  public var selectedHarness: ServerHarness? {
    harnesses.first { $0.id == selectedHarnessId }
  }

  public var isConnecting: Bool {
    if case .connecting = status { return true }
    return false
  }

  /// Whether the session is actively generating a response.
  public var isSending: Bool { model?.isSending ?? false }
  public var isCancelling: Bool { model?.isCancelling ?? false }
  public var isTakingLongerThanExpected: Bool {
    model?.isTakingLongerThanExpected ?? false
  }
  public var providerActivityPhase: SessionProviderActivityPhase? {
    model?.providerActivityPhase
  }
  public var connectionRecoveryMessage: String? {
    model?.connectionRecoveryMessage
  }

  /// User-facing text for a refusal-driven model swap, with both model ids
  /// resolved to display names where the live model option still lists them.
  /// The original usually is not listed once the swap is sticky, so its raw
  /// id is the expected fallback rather than an error case.
  public var modelFallbackMessage: String? {
    guard let fallback = model?.modelFallback else { return nil }
    let names =
      configOptions.first {
        $0.category == SessionConfigOption.Category.model || $0.id == "model"
      }?.options ?? []
    func name(_ value: String) -> String {
      names.first { $0.value == value }?.name ?? value
    }
    return "\(name(fallback.originalModel)) declined this request."
      + " Using \(name(fallback.fallbackModel)) for the rest of this chat."
  }

  public func dismissModelFallback() {
    model?.clearModelFallback()
  }

  public var isBusy: Bool {
    isConnecting || isSending
  }

  /// Background tasks the agent is running (backgrounded shells, subagents).
  public var backgroundTasks: [BackgroundTaskInfo] { model?.backgroundTasks ?? [] }

  /// Whether any background-task snapshot has arrived (see SessionModel).
  public var hasBackgroundTaskSnapshot: Bool { model?.hasBackgroundTaskSnapshot ?? false }

  /// Background tasks with no attachable terminal — the ones the waiting
  /// indicator describes. Terminal-backed tasks surface as terminal tabs.
  public var waitingBackgroundTasks: [BackgroundTaskInfo] { model?.waitingBackgroundTasks ?? [] }

  /// True when the turn ended but the agent still owns background work — the
  /// chat isn't stuck; the agent will come back on its own.
  public var isWaitingOnBackgroundTasks: Bool { model?.isWaitingOnBackgroundTasks ?? false }
  public var isRuntimeIdle: Bool { model?.isRuntimeIdle ?? true }
  public var lastTurnInitiator: SessionTurnInitiator { model?.lastTurnInitiator ?? .user }
  public var lastTurnEndedWithError: Bool { model?.lastTurnEndedWithError ?? false }

  public func canRetryTurn(_ id: UUID) -> Bool {
    guard !isSending else { return false }
    return conversation.reversed().first(where: {
      if case .assistant = $0 { return true }
      return false
    }).flatMap { item in
      guard case let .assistant(message) = item else { return nil }
      return message.id == id && message.turn.retryable
    } ?? false
  }

  /// Harness name while the server holds this chat's prompts during an
  /// update — drives the ephemeral "Waiting for X to finish updating…" row.
  public var waitingHarnessUpdateName: String? { model?.updateGateHarnessName }

  public var waitingBackgroundTaskDescription: String? {
    guard isWaitingOnBackgroundTasks else { return nil }
    let task = waitingBackgroundTasks.first
    let extra = waitingBackgroundTasks.count - 1
    return task.map {
      extra > 0 ? "\($0.description) and \(extra) more" : $0.description
    } ?? "background task"
  }

  /// Tool-call ids of subagents still running in the background (see
  /// SessionModel). Injected into the transcript so settled turns keep their
  /// subagent sections open and shimmering until the work finishes.
  public var runningSubagentToolCallIds: Set<String> { model?.runningSubagentToolCallIds ?? [] }

  public var canSend: Bool {
    (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !composerAttachments.isEmpty)
      && !isConnecting
      && !composerAttachments.contains { $0.state == .loading }
      && configurationValidationState == .ready
      && (isConnected || selectedHarness != nil)
  }
}
