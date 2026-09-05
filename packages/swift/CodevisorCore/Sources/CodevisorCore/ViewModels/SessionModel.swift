import Foundation
import Observation
import ACPKit

public enum SessionProviderActivityPhase: String, Equatable, Sendable {
  case modelStream
  case toolInputStream
  case toolExecution
  case retryBackoff
  case waitingForQuestion
  case cancelling

  public var label: String {
    switch self {
    case .modelStream: "model response"
    case .toolInputStream: "tool input"
    case .toolExecution: "tool execution"
    case .retryBackoff: "provider retry"
    case .waitingForQuestion: "your answer"
    case .cancelling: "cancellation"
    }
  }
}

struct TranscriptDetailsCacheEntry {
  let revision: Int
  let turn: AssistantTurn
}

/// Drives a single chat session: sends prompts, consumes the streamed
/// `SessionUpdate`s, and exposes an observable conversation for the UI.
@MainActor
@Observable
public final class SessionModel {
  /// Cheap boundary signal for off-main transcript projection. It advances
  /// only when a change can alter the stable row list; streaming mutations
  /// inside `activeItem` continue to invalidate only the active-row host.
  public private(set) var transcriptProjectionRevision: UInt64 = 0

  /// Recent history should produce a fast first paint even when a chat is
  /// made of giant markdown answers. Older rows arrive in larger reverse
  /// pages as the user approaches the top; the server also enforces a text
  /// budget so neither value can accidentally request megabytes of layout.
  /// Public so the controller can request the same first-page size through
  /// the combined open call and hand the result to `loadHistory(preloaded:)`.
  public static let initialTranscriptPageSize = 8
  static let olderTranscriptPageSize = 16
  /// Grace for a live terminal event after the cancel request completes.
  /// Internal mutability keeps reconciliation tests fast without changing
  /// the production two-second defense-in-depth window.
  static var cancellationTerminalEventWaitDelay: Duration = .milliseconds(100)
  /// Conversation items no longer receiving stream updates. Transcript
  /// containers should iterate THIS (plus a dedicated child view for
  /// `activeItem`), never `conversation`: the settled list changes only at
  /// bubble boundaries, so token flushes stop invalidating every row.
  public internal(set) var settledConversation: [ConversationItem] = [] {
    didSet { transcriptProjectionRevision &+= 1 }
  }
  /// The latest assistant bubble — the one token flushes mutate. Split out
  /// of the settled list so per-flush Observation invalidation is scoped to
  /// the single view that renders it; with one stored `conversation` array,
  /// every flush re-ran the whole transcript's body + AttributeGraph diff,
  /// which is O(transcript) and made streaming feel worse with every
  /// message (profiled: ~65% of the main thread inside NSHostingView
  /// layout/render on a long chat). Stays set after its turn finishes —
  /// settling happens lazily when the NEXT bubble starts — so finalize
  /// keeps the row's view identity (collapse animation, hover state).
  public internal(set) var activeItem: ConversationItem? {
    didSet {
      activeItemRevision &+= 1
      // Token flushes keep one identity and stay on the isolated active
      // host. Identity adoption and turn replacement need a new projected
      // row identity, otherwise a stale active row can bind to the next
      // assistant while its off-main projection is still pending.
      if activeItem?.id != oldValue?.id, hasActiveItem {
        transcriptProjectionRevision &+= 1
      }
    }
  }
  /// Cheap monotonic signal for the native row host. The active bubble is
  /// deliberately observed inside its own SwiftUI subtree, so its AppKit
  /// wrapper otherwise has no reliable indication that its intrinsic height
  /// may have changed during a token flush.
  public private(set) var activeItemRevision: UInt64 = 0
  /// Stored, boundary-guarded mirror of `activeItem != nil`: containers
  /// that only need existence (empty-state, setup-section placement) read
  /// this instead of `activeItem`, so they don't re-render per flush.
  public internal(set) var hasActiveItem = false {
    didSet {
      if hasActiveItem != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }

  /// The full conversation in display order. Convenience for callers that
  /// want a snapshot (persistence, tests, non-body logic). Body code should
  /// prefer `settledConversation`/`activeItem` — reading this tracks both.
  public var conversation: [ConversationItem] {
    if let activeItem {
      return settledConversation + [activeItem]
    }
    return settledConversation
  }
  public internal(set) var isSending = false {
    didSet {
      if isSending != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  public internal(set) var isCancelling = false
  /// Set when the harness reports a refusal-driven model swap. Not cleared at
  /// turn end: the swap is sticky for the session, so the notice stays true
  /// until the user dismisses it or picks a model themselves.
  public internal(set) var modelFallback: SessionModelFallback?
  public internal(set) var isTakingLongerThanExpected = false
  public internal(set) var providerActivityPhase: SessionProviderActivityPhase?
  /// Delayed, non-blocking transport recovery status for the active turn.
  /// Brief relay handoffs leave this nil so the existing Thinking/Waiting
  /// presentation remains stable instead of flashing connection plumbing.
  public internal(set) var connectionRecoveryMessage: String? {
    didSet {
      if connectionRecoveryMessage != oldValue { activeItemRevision &+= 1 }
    }
  }
  public internal(set) var queuedPrompts: [ServerPromptQueueItem] = []
  /// A deferred initial queue fetch must not overwrite a newer queue event
  /// that arrived after the transcript stream started.
  @ObservationIgnored var promptQueueRevision: UInt64 = 0
  @ObservationIgnored var promptQueueLoadTask: Task<Void, Never>?
  /// Set while the server holds this session's prompts during a harness
  /// update ("Waiting for Codex to finish updating…"); nil once released.
  public internal(set) var updateGateHarnessName: String? {
    didSet {
      if updateGateHarnessName != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  public var composerText: String = ""
  public internal(set) var availableCommands: [AvailableCommand] = []
  public internal(set) var modeState: SessionModeState?
  public internal(set) var configOptions: [SessionConfigOption]
  /// Monotonic per-picker revisions keep a failed, slower request from
  /// rolling back a newer optimistic selection for the same option.
  @ObservationIgnored var configMutationRevisions: [String: UInt64] = [:]
  public internal(set) var errorMessage: String? {
    didSet {
      if errorMessage != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  /// The most recent harness-auth failure is retained separately so a
  /// duplicate generic failure carrying the same server message does not
  /// erase its recovery action.
  var harnessAuthenticationErrorMessage: String?
  public var errorRequiresHarnessAuthentication: Bool {
    errorMessage != nil && harnessAuthenticationErrorMessage == errorMessage
  }
  /// Latest context-window + cost usage reported by the agent (`usage_update`).
  public internal(set) var usage: SessionUsage?
  /* Usage-limit state only feeds the temporarily disabled usage popover.
  public private(set) var usageLimits: ServerHarnessUsageLimits?
  public private(set) var isLoadingUsageLimits = false
  public private(set) var usageLimitsError: String?
  */
  /// Background tasks the agent is running (backgrounded shells, subagents),
  /// replaced wholesale on every server snapshot. Non-empty after a turn ends
  /// means the agent will come back on its own once the work settles.
  public internal(set) var backgroundTasks: [BackgroundTaskInfo] = [] {
    didSet {
      if backgroundTasks != oldValue { transcriptProjectionRevision &+= 1 }
      let ids = Set(backgroundTasks.compactMap { $0.taskType == "subagent" ? $0.toolUseId : nil })
      if ids != runningSubagentToolCallIds {
        runningSubagentToolCallIds = ids
      }
    }
  }
  /// Whether any snapshot has arrived yet. Terminal-tab pruning waits for
  /// this: before the first snapshot, an empty `backgroundTasks` just means
  /// history hasn't replayed, not that every task ended.
  public internal(set) var hasBackgroundTaskSnapshot = false
  public internal(set) var hasOlderHistory = false
  public internal(set) var isLoadingOlderHistory = false
  @ObservationIgnored var olderHistoryCursor: String?
  @ObservationIgnored var usesPaginatedHistory = false
  /// Fully hydrated worked details live with the in-memory session. A
  /// canonical summary page can therefore be reapplied without making an
  /// already-opened disclosure pass through a loading row again.
  @ObservationIgnored var transcriptDetailsCache: [String: TranscriptDetailsCacheEntry] = [:]
  /// One fetch per deferred item continues independently of a transient row
  /// host. Closing or virtualizing the disclosure cannot cancel useful work,
  /// and remounts simply await the same request.
  @ObservationIgnored var transcriptDetailLoadTasks: [String: Task<Bool, Never>] = [:]
  /// A compact active turn from another client must hydrate its worked
  /// events before post-snapshot socket updates are reduced. The socket is
  /// connected immediately, but its events remain buffered behind this
  /// session-owned task so the snapshot boundary stays lossless.
  @ObservationIgnored var activeTranscriptHydrationTask: Task<Void, Never>?
  @ObservationIgnored var activeTranscriptHydrationGeneration: UInt64 = 0
  @ObservationIgnored var isActiveTranscriptHydrationPending = false
  /// Constant-time routing for late/nested tool updates. Values are stable
  /// conversation ids, so prepending older pages cannot invalidate them.
  @ObservationIgnored var toolOwnerItemIds: [String: UUID] = [:]
  @ObservationIgnored var settledIndexById: [UUID: Int] = [:]

  /// Background tasks with no attachable terminal (subagents, poll-and-resume
  /// tasks). Tasks WITH a `terminalKey` render as terminal tabs instead of
  /// the waiting indicator — a dev server is running, not being waited on.
  public var waitingBackgroundTasks: [BackgroundTaskInfo] {
    backgroundTasks.filter { $0.terminalKey == nil }
  }

  /// True when the turn is over but the agent still owns background work —
  /// the "this chat is not stuck" signal. Terminal-backed tasks are excluded:
  /// their tab is the affordance.
  public var isWaitingOnBackgroundTasks: Bool {
    !isSending && !waitingBackgroundTasks.isEmpty
  }

  /// Claude's main-loop state. It is deliberately separate from background
  /// tasks: the SDK may be idle while a detached terminal process continues.
  public internal(set) var runtimeState: SessionRuntimeState = .idle
  public var isRuntimeIdle: Bool { runtimeState == .idle }

  /// Tool-call ids of subagents still running as background tasks, keyed by
  /// the `.agent` tool call that spawned them (the provider stamps the task's
  /// `toolUseId` with the spawning call id). A subagent's turn can end while
  /// it keeps working in the background; the transcript reads this to keep its
  /// section open and its label shimmering until it leaves the snapshot.
  /// Stored (maintained by `backgroundTasks.didSet`) because it is read in
  /// several view bodies per flush — computing it allocated a fresh Set per
  /// read, and only real membership changes should invalidate observers.
  public private(set) var runningSubagentToolCallIds: Set<String> = []

  /// The session's persistent goal, when the harness supports goal mode.
  /// Snapshots are idempotent full state — each update replaces the last.
  public internal(set) var goal: SessionGoal?
  /// A blocking agent question awaiting the user's answer — the composer
  /// renders as a picker while this is set. Cleared by the paired
  /// `question_resolved` event (replay collapses the pair) and at turn end.
  public internal(set) var pendingQuestion: QuestionRequest?
  public internal(set) var pendingPlanApproval = false
  /// True from the moment an answer or dismissal is accepted locally until
  /// the server acknowledges it. Callers use this for immediate feedback and
  /// to prevent duplicate operations while the blocking provider request is
  /// being released.
  public internal(set) var isResolvingQuestion = false
  /// The session's latest todo checklist across turns (codex update_plan,
  /// Claude TodoWrite, ACP plan updates). Full-snapshot replace; drives the
  /// pinned panel above the composer.
  public internal(set) var sessionPlan: Plan?

  /// Metadata for the most recent live turn-end callback. Sidebar attention
  /// uses this to fold autonomous follow-ups into the user-created activity
  /// epoch and to retain an unread failure after the controller is idle.
  public internal(set) var lastTurnInitiator: SessionTurnInitiator = .user
  public internal(set) var lastTurnEndedWithError = false

  /// Called each time a live turn ends (completed, cancelled, or failed) —
  /// the "chat finished" signal for surfaces outside this screen, like the
  /// sidebar's unread badge. Never fired by history replay.
  public var onTurnEnded: (() -> Void)?
  /// Fires for every SDK runtime-state edge, including repeated idle barriers.
  /// Consumers combine idle with the background-task level before declaring
  /// the overall activity epoch complete.
  public var onRuntimeStateChanged: (() -> Void)?
  /// Fires when a live goal snapshot changes. A terminal goal status is an
  /// attention barrier even when it arrives after the final turn-end event.
  public var onGoalChanged: (() -> Void)?
  /// Fired when a live agent question first blocks on the user. This is
  /// separate from turn end because question tools pause an in-flight turn.
  /// Never fired while replaying transcript history.
  public var onActionRequired: (() -> Void)?
  public var onPlanApprovalChanged: ((Bool) -> Void)?
  /// Fires only after the server accepts a new prompt queue item. Carries
  /// counts/state only; prompt and attachment content never leave the model.
  public var onPromptAccepted: ((_ attachmentCount: Int, _ isQueued: Bool) -> Void)?
  /// Fires synchronously after a direct user message and its assistant
  /// placeholder have been appended locally, before any transport wait.
  /// The controller uses this boundary to retire its matching pending row.
  public var onLocalUserMessageAppended: ((UUID) -> Void)?
  /// Fires when a queued prompt is claimed by the server and materializes as
  /// a user transcript row. The stable server message id distinguishes this
  /// handoff from queue edits/deletions and unrelated remote messages.
  public var onQueuedPromptPromoted: ((UUID?) -> Void)?
  /// Fires on every prompt-queue snapshot. A non-empty queue means more user
  /// turns are already committed, so attention consumers hold their epoch
  /// open until the queue drains (or the user clears it).
  public var onQueuedPromptsChanged: (() -> Void)?

  /// Replaced in place by `adoptTransport` when the machine's route flips;
  /// the conversation and its resume cursor survive the swap.
  var transport: ServerSessionTransport
  private let sessionId: String
  let now: @Sendable () -> Date
  let stalledTurnQuietInterval: Duration
  let quietTurnScheduler: SessionQuietTurnScheduler
  /// The server revision this model's state is current through. Seeded by
  /// the history page and advanced by every applied stream event, so a
  /// resubscription never replays what is already on screen.
  var serverEventCursor: Int?
  /// History contains complete config-option snapshots from the runtime that
  /// originally created the chat. During replay, retain only their selected
  /// values; the option catalog itself must come from the runtime connected
  /// today.
  var isReplayingHistory = false
  var historicalConfigSelections: [String: String] = [:]

  /// A single long-lived consumer of the session's event stream. The server
  /// delivers updates continuously — including agent-initiated turns with no
  /// prompt in flight — so one consumer runs for the model's lifetime.
  var consumerTask: Task<Void, Never>?
  @ObservationIgnored var stalledTurnSchedule: SessionQuietTurnCancellation?
  @ObservationIgnored var connectionRecoveryTask: Task<Void, Never>?
  @ObservationIgnored var surfacedConnectionRecoveryError: String?

  /// Recovery timing is injected per model so tests can exercise the full
  /// state ladder without mutating process-global clocks.
  let connectionRecoveryScheduler: SessionConnectionRecoveryScheduler
  let connectionRecoveryStatusDelay: Duration
  let connectionRecoveryFailureDelay: Duration
  let connectionRecoveryRetryBaseDelay: Duration
  let connectionRecoveryRetryMaximumDelay: Duration

  /// Stream events waiting for the next per-frame flush. Deliberately not
  /// observable: buffering must not invalidate views — only applying does.
  @ObservationIgnored nonisolated let pendingEvents = SessionEventBuffer()
  @ObservationIgnored var isFlushScheduled = false
  @ObservationIgnored var scheduledFlushTask: Task<Void, Never>?
  /// Installed by `SessionController`. Returning true means its presentation
  /// scheduler accepted responsibility for the pending flush.
  @ObservationIgnored var presentationFrameRequester: (@MainActor () -> Bool)?
  /// Queue claims are published just before their user-message event. Keep
  /// removed ids briefly so the second event can identify a real promotion;
  /// explicit deletions never produce a matching user-message id.
  @ObservationIgnored var pendingQueuePromotionIDs: [String: TimeInterval] = [:]
  /// User rows inserted locally before their server echo arrives. Modern
  /// servers echo the same id; this side table scopes the content fallback
  /// needed during rolling upgrades to those actual optimistic rows instead
  /// of treating any repeated user text as a duplicate.
  @ObservationIgnored var pendingOptimisticUserMessageIDs: Set<UUID> = []
  /// Fallback interval used before a native transcript clock attaches. Tests
  /// set this to zero so their yield-based settling needs no wall-clock wait.
  static var eventFlushInterval: Duration = .milliseconds(16)

  /// Flush cadence while no transcript view is mounted for this session.
  /// Events still apply in order and every lifecycle callback still fires —
  /// just on a coarser tick, so N backgrounded streams stop costing N×60
  /// main-actor reduce/CoW passes per second for pixels nobody can see.
  /// `viewDidAppear()` arms the native clock, so returning to a chat shows a
  /// fully caught-up transcript on its first visible frame.
  static var backgroundEventFlushInterval: Duration = .milliseconds(300)

  /// Number of mounted transcript views currently showing this model — a
  /// count, not a Bool, because one session can be on screen in several
  /// windows/splits at once. Deliberately not observable: visibility only
  /// tunes flush cadence, it must never invalidate views.
  @ObservationIgnored var visibleViewCount = 0
  var isViewVisible: Bool { visibleViewCount > 0 }

  @ObservationIgnored var presentationBoundarySleep: @Sendable (Duration) async throws -> Void = {
    try await Task.sleep(for: $0)
  }

  public init(
    serverTransport: ServerSessionTransport,
    sessionId: String,
    modeState: SessionModeState? = nil,
    configOptions: [SessionConfigOption] = [],
    now: @escaping @Sendable () -> Date = { Date() },
    stalledTurnQuietInterval: Duration = .seconds(300),
    quietTurnScheduler: SessionQuietTurnScheduler = .continuous,
    connectionRecoveryScheduler: SessionConnectionRecoveryScheduler = .continuous,
    connectionRecoveryStatusDelay: Duration = .seconds(5),
    connectionRecoveryFailureDelay: Duration = .seconds(30),
    connectionRecoveryRetryBaseDelay: Duration = .milliseconds(500),
    connectionRecoveryRetryMaximumDelay: Duration = .seconds(5)
  ) {
    self.transport = serverTransport
    self.sessionId = sessionId
    self.modeState = modeState
    self.configOptions = configOptions
    self.now = now
    self.stalledTurnQuietInterval = stalledTurnQuietInterval
    self.quietTurnScheduler = quietTurnScheduler
    self.connectionRecoveryScheduler = connectionRecoveryScheduler
    self.connectionRecoveryStatusDelay = connectionRecoveryStatusDelay
    self.connectionRecoveryFailureDelay = connectionRecoveryFailureDelay
    self.connectionRecoveryRetryBaseDelay = connectionRecoveryRetryBaseDelay
    self.connectionRecoveryRetryMaximumDelay = connectionRecoveryRetryMaximumDelay
  }

  @ObservationIgnored var appliedUpdateCount = 0
}
