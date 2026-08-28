import Foundation
import Observation
import ACPKit

/// The facade for a session screen. Holds the composer text and harness
/// selection, connects the session through the Codevisor server on first send,
/// then forwards to the live `SessionModel`.
@MainActor
@Observable
final public class SessionController {
    public enum Status: Equatable, Sendable {
        case idle
        case connecting(String)
        case failed(String)
    }

    /// Loading, an authoritative empty result, and a request failure are
    /// distinct UI states. An empty harness array alone cannot represent all
    /// three without briefly claiming that no agent is installed.
    public enum PreparationState: Equatable {
        case loading
        case ready
        case failed
    }

    /// Validation of a resumed chat's persisted composer configuration. The
    /// transcript is deliberately independent of this state; only actions
    /// that depend on current harness metadata wait for it.
    public enum ConfigurationValidationState: Equatable {
        case ready
        case connecting
        case failed(String)
    }

    /// The controller half of the transcript's cheap projection version.
    /// Model-backed row changes carry their own revision below.
    public private(set) var transcriptProjectionRevision: UInt64 = 0
    @ObservationIgnored let transcriptProjectionID = UUID()

    public var composerText: String = "" { didSet { draftDidChange() } }
    public internal(set) var composerAttachments: [ComposerAttachment] = [] { didSet { draftDidChange() } }
    var uploadTasks: [UUID: Task<Void, Never>] = [:]
    public internal(set) var harnesses: [ServerHarness] = []
    public internal(set) var preparationState: PreparationState = .loading
    /// True while the draft's model, mode, and harness capabilities are being
    /// fetched or decoded. This stays independent from `preparationState`:
    /// onboarding may supply a usable provisional harness catalog before the
    /// model definitions finish loading.
    public internal(set) var isRefreshingHarnessCapabilities = false
    public internal(set) var configurationValidationState: ConfigurationValidationState = .ready
    /// Non-nil when reconnecting replaced a persisted value that the harness
    /// no longer advertises.
    public internal(set) var configurationAdjustmentMessage: String?
    /// The first transcript page has its own state so an existing empty model
    /// never presents as an unexplained blank screen.
    public internal(set) var isLoadingInitialHistory = false {
        didSet {
            if isLoadingInitialHistory != oldValue { transcriptProjectionRevision &+= 1 }
        }
    }
    var initialHistoryLoadStartedAt: TimeInterval?
    public var selectedHarnessId: String? { didSet { draftDidChange() } }
    public internal(set) var model: SessionModel? {
        didSet {
            if model !== oldValue { transcriptProjectionRevision &+= 1 }
            // A model connected while its transcript is already on screen
            // must start at the visible flush cadence, not the background one.
            guard let model, model !== oldValue else { return }
            for _ in 0..<visibleTranscriptViews { model.viewDidAppear() }
        }
    }
    /// Mounted transcript views for this session, mirrored into the model so
    /// its stream-flush cadence matches whether anyone can actually see it.
    /// Kept here too because views can appear before the model connects.
    @ObservationIgnored var visibleTranscriptViews = 0
    public internal(set) var status: Status = .idle {
        didSet {
            if status != oldValue { transcriptProjectionRevision &+= 1 }
        }
    }
    /// Calm progress message shown while the eager connect waits for an
    /// unreachable server to come back (e.g. the managed server rebooting
    /// right after an app update). Non-nil only during that wait; the
    /// transcript renders it as a shimmer row instead of an error banner.
    public internal(set) var serverWaitMessage: String? {
        didSet {
            if serverWaitMessage != oldValue { transcriptProjectionRevision &+= 1 }
        }
    }
    /// A direct prompt staged at the accepted-send boundary. Both native
    /// clients render this exact message immediately, then the model adopts
    /// its id and retires this presentation copy. Keeping it for connected
    /// models too guarantees that an animation request is never published
    /// before its target row exists.
    public internal(set) var pendingUserMessage: UserMessage? {
        didSet {
            if pendingUserMessage != oldValue { transcriptProjectionRevision &+= 1 }
        }
    }
    /// The transcript scroll position, updated on every scroll tick and read
    /// back when the session screen remounts. Observation-ignored so the
    /// high-frequency writes don't invalidate views observing the controller.
    @ObservationIgnored public var scrollState: SessionScrollState? {
        didSet { onScrollStateChange?(scrollState) }
    }
    /// SessionStore mirrors viewport state independently from the heavier
    /// controller LRU, so browsing many chats can evict transcript models
    /// without forgetting where the user was reading.
    @ObservationIgnored public var onScrollStateChange: ((SessionScrollState?) -> Void)?
    /// Whether the pinned unfinished todo checklist is expanded. SessionStore
    /// mirrors this independently so navigation and controller eviction
    /// preserve the last state the user chose for each chat.
    public var isTodosExpanded = false {
        didSet { onTodosExpandedChange?(isTodosExpanded) }
    }
    @ObservationIgnored public var onTodosExpandedChange: ((Bool) -> Void)?
    /// User-toggled expand/collapse state for transcript rows, hoisted out of
    /// per-row `@State` so it survives lazy unmounts.
    @ObservationIgnored public let disclosure = TranscriptDisclosureStore()
    /// Bumped on every user send; the session screen observes it to re-pin
    /// the transcript to the bottom (sending means "show me the newest").
    public internal(set) var userSendSignal = 0
    /// The exact row eligible for the current send lift. Eligibility remains
    /// pending until a mounted native row atomically claims it; the coordinator
    /// remembers that claim across view rebuilds.
    public internal(set) var userSendAnimationRequest: UserSendAnimationRequest?
    @ObservationIgnored var userSendAnimationCoordinator = UserSendAnimationCoordinator()

    /// The project whose folder is used as the agent cwd. Settable so the
    /// new-chat page can change projects before the first send.
    public var project: Project { didSet { draftDidChange() } }
    /// Called once, on the first send — used by the new-chat page to create and
    /// register the real session and navigate to it.
    public var onFirstSend: (() -> Void)?
    /// Called when first-send setup fails after the draft was promoted. The
    /// owner reattaches the original draft persistence without deleting the
    /// durable chat session or its workspace.
    public var onSetupFailed: (() -> Void)?
    /// The agent session to resume (existing session); nil for a brand-new chat.
    public var resumeAgentSessionId: String?
    /// The durable Codevisor session mirrored by the server. Nil for a draft
    /// until first send. A session's working directory is decided by the
    /// new-chat pickers at first send and never changes afterward: the
    /// workspace created around it owns that one directory for life.
    public var serverSession: ChatSession?
    /// When true, the draft runs in a new git worktree created on the first
    /// send. Until the worktree exists there is no cwd to connect with, so
    /// the eager pre-connect is skipped.
    public var wantsNewWorktree = false {
        didSet {
            // A worktree kept alive from a reverted first send only makes
            // sense while worktree mode stays on; turning it off must drop
            // the override or the next send would still run in the worktree.
            if !wantsNewWorktree {
                sessionCwdOverride = nil
                worktreeName = nil
            }
            draftDidChange()
        }
    }
    /// The worktree created for this draft on first send (server-assigned slug).
    public internal(set) var worktreeName: String?
    /// The created worktree's path; overrides the project folder as the agent cwd.
    public internal(set) var sessionCwdOverride: String?
    /// Called once the first-send worktree has been created, so the owner can
    /// patch the already-registered session and workspace records with the
    /// worktree name/cwd.
    public var onWorktreeCreated: ((ServerWorktree) -> Void)?
    /// Pre-chat setup steps (worktree creation, agent start) shown in the
    /// transcript immediately after the optimistic first user message.
    public internal(set) var setupPhases: [SessionSetupPhase] = [] {
        didSet {
            if setupPhases != oldValue { transcriptProjectionRevision &+= 1 }
        }
    }
    /// A failed first-send setup returns to the centered New Chat treatment
    /// without deleting its durable session or workspace.
    public internal(set) var showsNewChatAfterSetupFailure = false
    /// Presentation state for an eagerly-created chat. Harness preparation may
    /// connect an agent before the user sends, so connection state cannot tell
    /// the container when to leave the centered New Chat treatment.
    public var shouldShowNewChatComposer: Bool {
        showsNewChatAfterSetupFailure || (!hasSentFirst && onFirstSend != nil)
    }
    /// The first send is accepted synchronously before worktree or agent setup
    /// begins, allowing the pane to enter the transcript without waiting for
    /// either asynchronous operation.
    public var hasAcceptedFirstSend: Bool { hasSentFirst }
    /// True from the moment a send is accepted until the first-send navigation
    /// has happened — the window where the new-chat composer shows a spinner
    /// and disables input.
    public internal(set) var isSubmitting = false
    /// Covers the whole question-resolution transaction, including the mode
    /// switch that precedes accepting Claude's ExitPlanMode prompt. The picker
    /// responds immediately and duplicate answer/cancel tasks are ignored.
    public internal(set) var isResolvingQuestion = false
    /// Called with the agent session id once a brand-new session is created.
    public var onAgentSessionCreated: ((String) -> Void)?
    /// Called each time a live turn ends — forwarded from the connected
    /// `SessionModel` so the session store can invalidate aggregate-activity
    /// observers. Unread state and notifications are server-projected and
    /// handled by `SessionAttentionCoordinator`.
    public var onTurnEnded: (() -> Void)?
    /// The agent session id currently connected (resumed or newly created).
    public internal(set) var connectedAgentSessionId: String?

    let configCache: ConfigOptionCache
    let composerDefaults: ComposerDefaultsStore?
    /// New-workspace drafts and in-workspace chats deliberately write to
    /// different inheritance profiles. Promotion changes this from the
    /// machine profile to the newly-created workspace profile.
    var composerDefaultsScope: ComposerDefaultsStore.Scope?
    /// The machine this chat talks to. Mutable for exactly one flow: a DRAFT
    /// retargeting to a project on another machine (`retarget(to:serverClient:)`).
    var serverClient: (any CodevisorServerClienting)?
    /// Platform notification delivery; nil in previews/tests. Only used to
    /// prepare authorization at the first send.
    let notificationDelivery: (any ChatNotificationDelivering)?
    var hasSentFirst = false
    var connectedHarnessId: String?
    /// Config changes made before connecting, applied once the agent connects.
    /// Keep these scoped to their harness so switching away and back does not
    /// discard that harness's model, thinking, or speed selection.
    var pendingConfigByHarness: [String: [String: String]] = [:] { didSet { draftDidChange() } }
    /// A compatible selection carried from another machine. Only ids and
    /// selected values cross the boundary; destination capability metadata
    /// remains the sole authority for whether they can be used. This stays
    /// alive after validation so a restored draft can distinguish the
    /// transient selection from the destination's durable fallback profile.
    @ObservationIgnored var automaticSelectionIntent: ComposerSelectionIntent?
    @ObservationIgnored var automaticSelectionNeedsResolution = false
    var pendingModeId: String? { didSet { draftDidChange() } }
    @ObservationIgnored public var onDraftChange: ((ComposerDraftStore.Draft) -> Void)?
    @ObservationIgnored var isRestoringDraft = false
    /// Set only while a promoted new-chat draft is waiting for a successful
    /// agent connection. Failed setup rolls it back without counting a chat.
    var pendingNewChatAnalytics = false
    /// The in-flight eager connect, owned by the controller so a pane remount
    /// (whose SwiftUI task dies with the view) cannot cancel it mid-flight.
    /// Callers of `connectIfNeeded()` join this attempt instead of racing the
    /// `.connecting` status guard. Cancelled only by an explicit supersede
    /// (`reconnect()`).
    @ObservationIgnored var connectAttempt: Task<Void, Never>?
    /// Usage snapshots are cumulative for a session; retain the previous one
    /// so turn events report coarse deltas instead of cumulative totals.
    var analyticsUsageBaseline: SessionUsage?
    /// The user's requested plan state while the harness/server transition is
    /// in flight. Keeping this separate from the authoritative session state
    /// makes the composer respond immediately without letting duplicate clicks
    /// race against the same stale mode value.
    var pendingPlanModeOn: Bool?
    var modeStateByHarness: [String: SessionModeState] = [:]
    var configOptionsByHarness: [String: [SessionConfigOption]] = [:]
    var supportsGoalsByHarness: [String: Bool] = [:]
    /// Invalidates older capability responses when a newer refresh starts or
    /// Settings changes the harness catalog while a request is in flight.
    var harnessCapabilityRequestRevision: UInt64 = 0
    /// Invalidates the completion phase of an older cross-machine retarget.
    /// Picker actions apply their target immediately, but capability fetches
    /// can suspend; only the newest target may reconnect afterwards.
    var retargetRevision: UInt64 = 0
    /// True while a model change is resolving the model-owned controls that
    /// accompany it. The composer keeps its popover geometry stable and shows
    /// an explicit loading state instead of briefly presenting stale settings.
    public internal(set) var isResolvingModelConfiguration = false
    var modelConfigurationResolutionRevision: UInt64 = 0
    var didLoadExistingHarnessCapabilities = false
    var didFinishExistingRuntimeConfiguration = false
    var didLoadExistingRuntimeConfiguration = false
    var existingConfigurationError: String?

    /// Goal-input mode: when armed, submitting the composer sets the text as
    /// the session goal instead of sending a prompt.
    public var isGoalComposerArmed = false { didSet { draftDidChange() } }

    /// The pencil-edit flow: the composer strips down to a dedicated
    /// "Edit goal" editor and the banner hides. Plain ⌖-armed goal setting
    /// keeps the normal composer look.
    public var isGoalEditing = false { didSet { draftDidChange() } }

    /// Editing an existing goal temporarily replaces the visible chat draft.
    /// Keep the draft here so cancelling or finishing the edit cannot destroy
    /// text the user had already composed.
    var composerTextBeforeGoalEdit: String? { didSet { draftDidChange() } }

    /// A goal captured before the session connected, applied on connect.
    var pendingGoal: String?

    /// Codex has no ExitPlanMode tool: when a plan-mode turn ends having
    /// proposed a plan, we surface the same "implement this plan?" picker as a
    /// client-side prompt. Answering it messages the model (there is no held
    /// tool to resolve) — mirroring codex CLI's approve = leave-plan-mode +
    /// "Implement the plan." user turn.
    public internal(set) var pendingPlanApproval = false

    public init(
        project: Project,
        configCache: ConfigOptionCache,
        composerDefaults: ComposerDefaultsStore? = nil,
        composerDefaultsScope: ComposerDefaultsStore.Scope? = nil,
        serverClient: (any CodevisorServerClienting)? = nil,
        notificationDelivery: (any ChatNotificationDelivering)? = nil
    ) {
        self.project = project
        self.configCache = configCache
        self.composerDefaults = composerDefaults
        self.composerDefaultsScope =
            composerDefaultsScope
            ?? composerDefaults.map { _ in .newWorkspace(serverId: project.serverId) }
        self.serverClient = serverClient
        self.notificationDelivery = notificationDelivery
        if seedFromCachedServerCapabilities() {
            preparationState = .ready
        }
    }
}

struct ComposerSelectionIntent: Equatable {
    let harnessId: String
    let configValues: [String: String]
    let modelValue: String?
}

public enum SessionControllerError: Error {
    /// Sessions run through the Codevisor server; without it there is nothing to
    /// connect to.
    case serverUnavailable
}

#if DEBUG
    extension SessionController {
        /// A controller pre-populated for previews.
        static public func preview(
            project: Project = Project.fromFolder(URL(fileURLWithPath: "/tmp/shepherd")),
            model: SessionModel? = nil,
            harnesses: [ServerHarness] = SessionController.previewHarnesses
        ) -> SessionController {
            let controller = SessionController(
                project: project,
                configCache: ConfigOptionCache(store: InMemoryStore())
            )
            controller.harnesses = harnesses
            controller.preparationState = .ready
            controller.selectedHarnessId = harnesses.first?.id
            controller.model = model
            // Surface the plan and goal affordances in previews: goals for every
            // sample harness, and a plan/build mode pair for the draft (no-model)
            // composer, mirroring what capabilities discovery would report.
            for harness in harnesses {
                controller.supportsGoalsByHarness[harness.id] = true
                controller.modeStateByHarness[harness.id] = SessionModeState(
                    currentModeId: "default",
                    availableModes: [
                        SessionMode(id: "default", name: "Default", canonicalId: "fullAccess"),
                        SessionMode(id: "plan", name: "Plan", canonicalId: "plan"),
                    ]
                )
            }
            return controller
        }

        nonisolated static public var previewHarnesses: [ServerHarness] {
            [
                ServerHarness(
                    id: "claude-code", name: "Claude Code", symbolName: "sparkle", source: "registry",
                    launchKind: "executable", enabled: true,
                    readiness: ServerHarnessReadiness(state: "ready")
                ),
                ServerHarness(
                    id: "codex", name: "Codex", symbolName: "chevron.left.forwardslash.chevron.right",
                    source: "registry", launchKind: "executable", enabled: true,
                    readiness: ServerHarnessReadiness(state: "ready")
                ),
            ]
        }
    }
#endif
