import Foundation
import Observation
import ACPKit
import UniformTypeIdentifiers
import os

/// A file staged in the composer: bytes held locally for instant thumbnails,
/// uploaded eagerly so send only has to collect the server refs.
public struct ComposerAttachment: Identifiable, Equatable {
    public enum State: Equatable {
        case uploading
        case uploaded(ServerAttachmentRef)
        case failed(String)
    }

    public let id: UUID
    public var name: String
    public var mimeType: String
    public var kind: Attachment.Kind
    public var localData: Data
    public var state: State

    public var isImage: Bool { kind == .image }

    public var isPDF: Bool {
        mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
    }

    public var isVideo: Bool { attachmentIsVideo(name: name, mimeType: mimeType) }

    /// Images, PDFs, and videos render as visual previews; everything else is a chip.
    public var hasVisualPreview: Bool { isImage || isPDF || isVideo }
}

/// Whether an attachment is a video, by MIME type first and filename
/// extension (via UTType) as fallback. Shared by the composer model and the
/// attachment views.
public func attachmentIsVideo(name: String, mimeType: String) -> Bool {
    if mimeType.lowercased().hasPrefix("video/") { return true }
    let pathExtension = (name as NSString).pathExtension
    guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else {
        return false
    }
    return type.conforms(to: .movie)
}

/// One request to animate a user message from the composer into its transcript
/// row. The token distinguishes requests even if a caller deliberately reuses
/// a message id.
public struct UserSendAnimationRequest: Equatable, Sendable {
    public let token: UInt64
    public let messageID: UUID

    public init(token: UInt64, messageID: UUID) {
        self.token = token
        self.messageID = messageID
    }
}

/// Exactly-once ownership for send animations. This state outlives native
/// transcript views, so rebuilding a SwiftUI/AppKit surface cannot claim the
/// same request again.
struct UserSendAnimationCoordinator {
    private var nextToken: UInt64 = 0
    private var currentRequest: UserSendAnimationRequest?
    private var claimedToken: UInt64?

    mutating func issue(for messageID: UUID) -> UserSendAnimationRequest {
        nextToken &+= 1
        let request = UserSendAnimationRequest(token: nextToken, messageID: messageID)
        currentRequest = request
        return request
    }

    mutating func claim(_ request: UserSendAnimationRequest) -> Bool {
        guard currentRequest == request, claimedToken != request.token else { return false }
        claimedToken = request.token
        return true
    }

    mutating func cancel(_ request: UserSendAnimationRequest) {
        guard currentRequest == request else { return }
        currentRequest = nil
    }
}

/// One measured settled-row height. The revision prevents a stale height from
/// being reused if the row's content changed while it was offscreen.
public struct SessionMeasuredRow: Equatable {
    public var height: CGFloat
    public var revision: Int

    public init(height: CGFloat, revision: Int) {
        self.height = height
        self.revision = revision
    }
}

/// Text layout depends on the actual row width and the app's typography. Keep
/// those dimensions in the cache key so a sidebar resize cannot poison a later
/// restoration at another width.
public struct SessionMeasurementCacheKey: Hashable {
    /// Effective row width in half-point buckets. Sub-pixel window jitter does
    /// not create a new cache, while a real reflow does.
    public var rowWidthHalfPoints: Int
    public var layoutFingerprint: Int

    public init(rowWidthHalfPoints: Int, layoutFingerprint: Int) {
        self.rowWidthHalfPoints = rowWidthHalfPoints
        self.layoutFingerprint = layoutFingerprint
    }
}

/// The mounted virtual window saved alongside a transcript coordinate. This
/// mirrors ChatGPT's `renderedWindow`: restoration mounts the same neighborhood
/// before any estimates are allowed to choose a different part of the thread.
public struct SessionRenderedTranscriptWindow: Equatable {
    public var anchorKey: String
    public var count: Int

    public init(anchorKey: String, count: Int) {
        self.anchorKey = anchorKey
        self.count = count
    }
}

/// Virtualizer-owned restore data. The height map is the exact geometry that
/// produced the saved coordinate; the regular LRU remains the longer-lived
/// cache used across width changes.
public struct SessionVirtualTranscriptRestoreState: Equatable {
    public var measurementCacheKey: SessionMeasurementCacheKey?
    public var rowHeightsByKey: [String: CGFloat]
    /// Revisions for the settled subset of `rowHeightsByKey`. Restore applies
    /// a settled row's saved height only when its revision still matches the
    /// current transcript — content can change while a pane is closed (e.g. a
    /// background subagent streaming into an already-ended turn).
    public var settledRowsByKey: [String: SessionMeasuredRow] = [:]
    public var renderedWindow: SessionRenderedTranscriptWindow?

    public init(
        measurementCacheKey: SessionMeasurementCacheKey?,
        rowHeightsByKey: [String: CGFloat],
        settledRowsByKey: [String: SessionMeasuredRow] = [:],
        renderedWindow: SessionRenderedTranscriptWindow? = nil
    ) {
        self.measurementCacheKey = measurementCacheKey
        self.rowHeightsByKey = rowHeightsByKey
        self.settledRowsByKey = settledRowsByKey
        self.renderedWindow = renderedWindow
    }
}

/// User intent for how the transcript should react to future content. This is
/// deliberately independent from viewport geometry: restoring or remeasuring
/// rows can move the viewport a few points without meaning that the user chose
/// to stop following the latest turn.
public enum SessionTranscriptFollowMode: Equatable {
    case staticPosition
    case followingLatest

    public var followsLatest: Bool { self == .followingLatest }
}

/// Where the transcript was scrolled when the user last looked at a session,
/// kept on the cached controller so navigating away and back reopens the
/// transcript at the same place instead of pinned to the bottom.
public struct SessionScrollState {
    /// The single persisted viewport coordinate, matching ChatGPT's thread
    /// scroll model. Zero means the latest content is visible.
    public var distanceFromBottom: CGFloat
    /// A tiny, bounded LRU of exact settled-row measurements. Dictionary
    /// snapshots are copy-on-write, so publishing scroll state remains O(1).
    public var measurementCaches: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]]
    public var measurementCacheLRU: [SessionMeasurementCacheKey]
    /// Exact virtual window and row geometry from the last mounted view.
    public var virtualTranscript: SessionVirtualTranscriptRestoreState?
    /// Follow intent is persisted separately from the viewport coordinate.
    public var followMode: SessionTranscriptFollowMode
    public var isAtBottom: Bool { distanceFromBottom <= 2 }

    public init(
        distanceFromBottom: CGFloat,
        measurementCaches: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]],
        measurementCacheLRU: [SessionMeasurementCacheKey],
        virtualTranscript: SessionVirtualTranscriptRestoreState? = nil,
        followMode: SessionTranscriptFollowMode
    ) {
        self.distanceFromBottom = distanceFromBottom
        self.measurementCaches = measurementCaches
        self.measurementCacheLRU = measurementCacheLRU
        self.virtualTranscript = virtualTranscript
        self.followMode = followMode
    }
}

/// The facade for a session screen. Holds the composer text and harness
/// selection, connects the session through the Codevisor server on first send,
/// then forwards to the live `SessionModel`.
@MainActor
@Observable
final public class SessionController {
    public enum Status: Equatable {
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

    public var composerText: String = "" { didSet { draftDidChange() } }
    public private(set) var composerAttachments: [ComposerAttachment] = [] { didSet { draftDidChange() } }
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    public private(set) var harnesses: [ServerHarness] = []
    public private(set) var preparationState: PreparationState = .loading
    public private(set) var configurationValidationState: ConfigurationValidationState = .ready
    /// Non-nil when reconnecting replaced a persisted value that the harness
    /// no longer advertises.
    public private(set) var configurationAdjustmentMessage: String?
    /// The first transcript page has its own state so an existing empty model
    /// never presents as an unexplained blank screen.
    public private(set) var isLoadingInitialHistory = false
    private var initialHistoryLoadStartedAt: TimeInterval?
    public var selectedHarnessId: String? { didSet { draftDidChange() } }
    public private(set) var model: SessionModel? {
        didSet {
            // A model connected while its transcript is already on screen
            // must start at the visible flush cadence, not the background one.
            guard let model, model !== oldValue else { return }
            for _ in 0..<visibleTranscriptViews { model.viewDidAppear() }
        }
    }
    /// Mounted transcript views for this session, mirrored into the model so
    /// its stream-flush cadence matches whether anyone can actually see it.
    /// Kept here too because views can appear before the model connects.
    @ObservationIgnored private var visibleTranscriptViews = 0
    public private(set) var status: Status = .idle
    /// Calm progress message shown while the eager connect waits for an
    /// unreachable server to come back (e.g. the managed server rebooting
    /// right after an app update). Non-nil only during that wait; the
    /// transcript renders it as a shimmer row instead of an error banner.
    public private(set) var serverWaitMessage: String?
    /// A direct prompt staged at the accepted-send boundary. Both native
    /// clients render this exact message immediately, then the model adopts
    /// its id and retires this presentation copy. Keeping it for connected
    /// models too guarantees that an animation request is never published
    /// before its target row exists.
    public private(set) var pendingUserMessage: UserMessage?
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
    public var isTodosExpanded = true {
        didSet { onTodosExpandedChange?(isTodosExpanded) }
    }
    @ObservationIgnored public var onTodosExpandedChange: ((Bool) -> Void)?
    /// User-toggled expand/collapse state for transcript rows, hoisted out of
    /// per-row `@State` so it survives lazy unmounts.
    @ObservationIgnored public let disclosure = TranscriptDisclosureStore()
    /// Bumped on every user send; the session screen observes it to re-pin
    /// the transcript to the bottom (sending means "show me the newest").
    public private(set) var userSendSignal = 0
    /// The exact row eligible for the current send lift. Eligibility remains
    /// pending until a mounted native row atomically claims it; the coordinator
    /// remembers that claim across view rebuilds.
    public private(set) var userSendAnimationRequest: UserSendAnimationRequest?
    @ObservationIgnored private var userSendAnimationCoordinator = UserSendAnimationCoordinator()

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
    public private(set) var worktreeName: String?
    /// The created worktree's path; overrides the project folder as the agent cwd.
    public private(set) var sessionCwdOverride: String?
    /// Called once the first-send worktree has been created, so the owner can
    /// patch the already-registered session and workspace records with the
    /// worktree name/cwd.
    public var onWorktreeCreated: ((ServerWorktree) -> Void)?
    /// Pre-chat setup steps (worktree creation, agent start) shown in the
    /// transcript immediately after the optimistic first user message.
    public private(set) var setupPhases: [SessionSetupPhase] = []
    /// A failed first-send setup returns to the centered New Chat treatment
    /// without deleting its durable session or workspace.
    public private(set) var showsNewChatAfterSetupFailure = false
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
    public private(set) var isSubmitting = false
    /// Covers the whole question-resolution transaction, including the mode
    /// switch that precedes accepting Claude's ExitPlanMode prompt. The picker
    /// responds immediately and duplicate answer/cancel tasks are ignored.
    public private(set) var isResolvingQuestion = false
    /// Called with the agent session id once a brand-new session is created.
    public var onAgentSessionCreated: ((String) -> Void)?
    /// Called each time a live turn ends — forwarded from the connected
    /// `SessionModel` so the session store can badge unopened chats.
    public var onTurnEnded: (() -> Void)?
    /// Called for Claude runtime-state barriers so deferred attention can be
    /// released only after the overall activity epoch becomes quiescent.
    public var onRuntimeStateChanged: (() -> Void)?
    /// Called when goal state changes so terminal goal outcomes can release a
    /// deferred unread/notification epoch.
    public var onGoalChanged: (() -> Void)?
    /// Called when the prompt queue changes so a deferred attention epoch can
    /// be released once the last queued prompt is claimed or removed.
    public var onQueuedPromptsChanged: (() -> Void)?
    /// Called when a live question pauses the agent for user input.
    public var onActionRequired: (() -> Void)?
    /// The agent session id currently connected (resumed or newly created).
    public private(set) var connectedAgentSessionId: String?

    private let configCache: ConfigOptionCache
    private let composerDefaults: ComposerDefaultsStore?
    /// New-workspace drafts and in-workspace chats deliberately write to
    /// different inheritance profiles. Promotion changes this from the
    /// machine profile to the newly-created workspace profile.
    private var composerDefaultsScope: ComposerDefaultsStore.Scope?
    private let serverClient: (any CodevisorServerClienting)?
    /// Platform notification delivery; nil in previews/tests. Only used to
    /// prepare authorization at the first send.
    private let notificationDelivery: (any ChatNotificationDelivering)?
    private var hasSentFirst = false
    private var connectedHarnessId: String?
    /// Config changes made before connecting, applied once the agent connects.
    /// Keep these scoped to their harness so switching away and back does not
    /// discard that harness's model, thinking, or speed selection.
    private var pendingConfigByHarness: [String: [String: String]] = [:] { didSet { draftDidChange() } }
    private var pendingModeId: String? { didSet { draftDidChange() } }
    @ObservationIgnored public var onDraftChange: ((ComposerDraftStore.Draft) -> Void)?
    @ObservationIgnored private var isRestoringDraft = false
    /// Set only while a promoted new-chat draft is waiting for a successful
    /// agent connection. Failed setup rolls it back without counting a chat.
    private var pendingNewChatAnalytics = false
    /// The in-flight eager connect, owned by the controller so a pane remount
    /// (whose SwiftUI task dies with the view) cannot cancel it mid-flight.
    /// Callers of `connectIfNeeded()` join this attempt instead of racing the
    /// `.connecting` status guard. Cancelled only by an explicit supersede
    /// (`reconnect()`).
    @ObservationIgnored private var connectAttempt: Task<Void, Never>?
    /// Usage snapshots are cumulative for a session; retain the previous one
    /// so turn events report coarse deltas instead of cumulative totals.
    private var analyticsUsageBaseline: SessionUsage?
    /// The user's requested plan state while the harness/server transition is
    /// in flight. Keeping this separate from the authoritative session state
    /// makes the composer respond immediately without letting duplicate clicks
    /// race against the same stale mode value.
    private var pendingPlanModeOn: Bool?
    private var modeStateByHarness: [String: SessionModeState] = [:]
    private var configOptionsByHarness: [String: [SessionConfigOption]] = [:]
    private var supportsGoalsByHarness: [String: Bool] = [:]
    private var didLoadExistingHarnessCapabilities = false
    private var didFinishExistingRuntimeConfiguration = false
    private var didLoadExistingRuntimeConfiguration = false
    private var existingConfigurationError: String?

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
        self.composerDefaultsScope = composerDefaultsScope
            ?? composerDefaults.map { _ in .newWorkspace(serverId: project.serverId) }
        self.serverClient = serverClient
        self.notificationDelivery = notificationDelivery
        if seedFromCachedServerCapabilities() {
            preparationState = .ready
        }
    }

    /// Binds a persisted chat to this controller and paints its last accepted
    /// selections over cached option definitions. The values remain
    /// provisional until the live session reconnect validates them.
    public func configureExistingSession(_ session: ChatSession) {
        let identityChanged = serverSession?.id != session.id
            || resumeAgentSessionId != session.agentSessionId
        serverSession = session
        resumeAgentSessionId = session.agentSessionId
        if !session.harnessId.isEmpty {
            selectedHarnessId = session.harnessId
        }
        guard model == nil else { return }
        seedExistingSessionConfiguration(from: session)
        // An in-flight connect owns the validation state machine: a refresh
        // snapshot arriving mid-connect usually carries the agent session id
        // that this very connect just minted server-side (`session.updated`
        // from `ensureAgentSessionFor`). Resetting to `.connecting` here would
        // wedge the composer forever — nothing on the send path recomputes the
        // state after the model is published. The id itself was still adopted
        // above; the connect settles the flags when it completes.
        guard identityChanged, session.agentSessionId?.isEmpty == false, !isConnecting else { return }
        didLoadExistingHarnessCapabilities = false
        didFinishExistingRuntimeConfiguration = false
        didLoadExistingRuntimeConfiguration = false
        existingConfigurationError = nil
        configurationAdjustmentMessage = nil
        configurationValidationState = .connecting
        isLoadingInitialHistory = true
        initialHistoryLoadStartedAt = ProcessInfo.processInfo.systemUptime
    }

    private func seedExistingSessionConfiguration(from session: ChatSession? = nil) {
        let session = session ?? serverSession
        guard model == nil,
              let session,
              !session.harnessId.isEmpty,
              let selections = session.configSelections,
              !selections.isEmpty else { return }
        var options = configOptionsByHarness[session.harnessId]
            ?? configCache.options(forHarness: session.harnessId, onServer: project.serverId)
        for (configId, value) in selections {
            if let index = options.firstIndex(where: { $0.id == configId }) {
                // Keep even a now-unknown value visible while validation runs;
                // SessionConfigOption.currentName falls back to the raw value.
                options[index].currentValue = value
            } else {
                // The value snapshot is enough to paint a disabled provisional
                // picker even when this machine has no cached definitions yet.
                options.append(Self.provisionalConfigOption(id: configId, value: value))
            }
        }
        configOptionsByHarness[session.harnessId] = options
    }

    private static func provisionalConfigOption(id: String, value: String) -> SessionConfigOption {
        let normalized = id.lowercased()
        let category: String? = if normalized == "model" {
            SessionConfigOption.Category.model
        } else if normalized.contains("reason")
            || normalized.contains("effort")
            || normalized.contains("thinking") {
            SessionConfigOption.Category.thoughtLevel
        } else if normalized.contains("speed") {
            SessionConfigOption.Category.speed
        } else {
            SessionConfigOption.Category.modelConfig
        }
        return SessionConfigOption(
            id: id,
            name: id.replacingOccurrences(of: "_", with: " ").capitalized,
            category: category,
            currentValue: value,
            options: [SessionConfigSelectOption(value: value, name: value)]
        )
    }

    private var hasExistingAgentSession: Bool {
        resumeAgentSessionId?.isEmpty == false
            || serverSession?.agentSessionId?.isEmpty == false
    }

    public var isConnectingToHarness: Bool {
        configurationValidationState == .connecting
    }

    public var configurationValidationError: String? {
        guard case let .failed(message) = configurationValidationState else { return nil }
        return message
    }

    private func updateConfigurationValidationState() {
        guard hasExistingAgentSession else {
            configurationValidationState = .ready
            return
        }
        if didLoadExistingRuntimeConfiguration
            || (didFinishExistingRuntimeConfiguration && didLoadExistingHarnessCapabilities) {
            configurationValidationState = .ready
        } else if didFinishExistingRuntimeConfiguration,
                  let existingConfigurationError {
            configurationValidationState = .failed(existingConfigurationError)
        } else {
            configurationValidationState = .connecting
        }
    }

    public func draftSnapshot() -> ComposerDraftStore.Draft {
        ComposerDraftStore.Draft(
            projectId: project.id,
            composerText: composerText,
            attachments: composerAttachments.map {
                ComposerDraftStore.DraftAttachment(
                    id: $0.id,
                    name: $0.name,
                    mimeType: $0.mimeType,
                    kind: $0.kind.rawValue,
                    localData: $0.localData
                )
            },
            selectedHarnessId: selectedHarnessId,
            configByHarness: pendingConfigByHarness,
            modeId: pendingModeId,
            isGoalComposerArmed: isGoalComposerArmed,
            isGoalEditing: isGoalEditing,
            composerTextBeforeGoalEdit: composerTextBeforeGoalEdit
        )
    }

    public func restoreDraft(_ draft: ComposerDraftStore.Draft) {
        isRestoringDraft = true
        composerText = draft.composerText
        composerAttachments = draft.attachments.map {
            ComposerAttachment(
                id: $0.id,
                name: $0.name,
                mimeType: $0.mimeType,
                kind: Attachment.Kind(rawValue: $0.kind) ?? .file,
                localData: $0.localData,
                state: .uploading
            )
        }
        selectedHarnessId = draft.selectedHarnessId
        pendingConfigByHarness = draft.configByHarness
        pendingModeId = draft.modeId
        isGoalComposerArmed = draft.isGoalComposerArmed
        isGoalEditing = draft.isGoalEditing
        composerTextBeforeGoalEdit = draft.composerTextBeforeGoalEdit
        isRestoringDraft = false

        // Drafts written by an older app may contain explicit selections that
        // predate immediate defaults persistence. Promote all per-harness
        // config first, then make the draft's selected harness the global
        // winner. This preserves an unsent user's choices across the update.
        if let composerDefaults {
            for (harnessId, configValues) in draft.configByHarness {
                composerDefaults.rememberConfigSelections(
                    in: resolvedComposerDefaultsScope,
                    harnessId: harnessId,
                    configValues: configValues
                )
            }
            composerDefaults.rememberHarnessSelection(
                in: resolvedComposerDefaultsScope,
                harnessId: draft.selectedHarnessId
            )
        }

        // Server file ids are not assumed to survive indefinitely. Re-upload
        // the persisted local bytes and produce fresh refs for the next send.
        for attachment in composerAttachments { startUpload(attachment) }
    }

    private func draftDidChange() {
        guard !isRestoringDraft, isDraft, let onDraftChange else { return }
        onDraftChange(draftSnapshot())
    }

    public var isPrepared: Bool { preparationState == .ready }

    /// The directory the agent runs in: the session's server-resolved cwd
    /// (the workspace's one working directory — project folder or worktree),
    /// or the project folder for plain drafts.
    public var sessionCwdURL: URL {
        if let cwd = serverSession?.cwd { return URL(fileURLWithPath: cwd) }
        if let sessionCwdOverride { return URL(fileURLWithPath: sessionCwdOverride) }
        return project.folderURL
    }

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
            && serverSession?.agentSessionId == nil
            && resumeAgentSessionId == nil
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
           message.turn.stopDetail == error {
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

    // MARK: - Goals

    /// The session's persistent goal, when the harness supports goal mode.
    public var goal: SessionGoal? { model?.goal }

    /// Whether the selected harness supports goals at all — gates every goal
    /// affordance; harnesses without support show nothing.
    public var supportsGoals: Bool {
        guard let harnessId = connectedHarnessId ?? selectedHarnessId else { return false }
        return supportsGoalsByHarness[harnessId] ?? false
    }

    /// The goal affordance shows whenever the harness supports goals; a goal
    /// set before the first send is held and applied once the agent connects.
    public var canEditGoal: Bool { supportsGoals }

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
    private var composerTextBeforeGoalEdit: String? { didSet { draftDidChange() } }

    /// A goal captured before the session connected, applied on connect.
    private var pendingGoal: String?

    public func toggleGoalComposer() {
        if isGoalComposerArmed {
            exitGoalComposer()
        } else {
            isGoalComposerArmed = true
            // Plan and goal are mutually exclusive: arming the goal composer
            // leaves plan mode.
            if isPlanModeOn, !isPlanModeUpdatePending {
                Task { await togglePlanMode() }
            }
        }
    }

    /// Leaves goal mode without mutating an ordinary composer draft. Editing
    /// an existing goal restores the chat draft that the edit displaced.
    public func exitGoalComposer() {
        isGoalComposerArmed = false
        isGoalEditing = false
        if let composerTextBeforeGoalEdit {
            composerText = composerTextBeforeGoalEdit
            self.composerTextBeforeGoalEdit = nil
        }
    }

    /// Loads the current goal into the composer in edit mode — submitting
    /// replaces the objective.
    public func editGoal() {
        guard let objective = (goal ?? draftGoal)?.objective else { return }
        composerTextBeforeGoalEdit = composerText
        composerText = objective
        isGoalComposerArmed = true
        isGoalEditing = true
    }

    /// Submits the composer text as the goal (the armed-toggle send path).
    /// On a new chat this mirrors `send()`: navigate to the session page,
    /// create the worktree/session, connect the agent — with the goal applied
    /// on connect instead of a prompt.
    public func submitGoalFromComposer() async {
        let objective = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty, !isConnecting, !isSubmitting else { return }

        if let model {
            guard await model.setGoal(objective: objective) else { return }
            isGoalComposerArmed = false
            isGoalEditing = false
            composerText = composerTextBeforeGoalEdit ?? ""
            composerTextBeforeGoalEdit = nil
            return
        }

        isGoalComposerArmed = false
        isGoalEditing = false
        pendingGoal = objective
        showsNewChatAfterSetupFailure = false
        status = .idle
        isSubmitting = true
        let showsSetupPhases =
            (pendingNewChatAnalytics || (!hasSentFirst && onFirstSend != nil))
                && resumeAgentSessionId == nil
        // Navigate first, exactly like a first prompt send.
        if !hasSentFirst {
            hasSentFirst = true
            if onFirstSend != nil {
                pendingNewChatAnalytics = true
            }
            onFirstSend?()
            onFirstSend = nil
        }
        isSubmitting = false
        composerText = ""
        func restoreComposer() {
            composerText = objective
            pendingGoal = nil
            isGoalComposerArmed = true
        }

        // Materialize the worktree before the agent exists, exactly like a
        // first prompt send (see send()).
        if wantsNewWorktree, sessionCwdOverride == nil {
            if let failure = await createWorktree(showsSetupPhase: showsSetupPhases) {
                restoreComposer()
                handleSetupFailure(failure, returnsToNewChat: showsSetupPhases)
                return
            }
        }

        guard let harness = selectedHarness else {
            let message = "No agent is installed. Install Claude Code or Codex and try again."
            restoreComposer()
            handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
            return
        }
        status = .connecting("Starting \(harness.name)…")
        if showsSetupPhases { beginSetupPhase(.startingAgent(named: harness.name)) }
        do {
            // connect applies the pending goal once the agent session exists.
            let model = try await connect(harnessId: harness.id)
            self.model = model
            setupPhases.removeAll { $0.id == SessionSetupPhase.agentPhaseId }
            status = .idle
        } catch {
            let message = serverErrorMessage(error)
            restoreComposer()
            handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
        }
    }

    public func setGoal(objective: String? = nil, status: GoalStatus? = nil) async {
        if let model {
            await model.setGoal(objective: objective, status: status)
        } else if let objective {
            pendingGoal = objective
        }
    }

    /// The pre-connect goal shown in the banner before the session exists.
    /// Kept visible until the live goal replaces it, so the banner doesn't
    /// flicker out during the connect handshake.
    public var draftGoal: SessionGoal? {
        guard model?.goal == nil, let pendingGoal else { return nil }
        return SessionGoal(objective: pendingGoal, status: .active)
    }

    /// Applies a goal captured before connect. Called once the model exists.
    /// The draft clears only after the live goal is set (no banner gap).
    private func applyPendingGoal(to model: SessionModel) async {
        guard let pendingGoal else { return }
        if await model.setGoal(objective: pendingGoal) {
            self.pendingGoal = nil
        }
    }

    public func pauseGoal() async { await model?.pauseGoal() }
    public func resumeGoal() async { await model?.resumeGoal() }

    public func clearGoal() async {
        if model == nil {
            pendingGoal = nil
        } else {
            await model?.clearGoal()
        }
    }

    // MARK: - Todos

    /// The session's latest todo checklist, pinned above the composer.
    public var todos: Plan? { model?.sessionPlan }

    /// Completed checklists stay in the transcript but no longer occupy the
    /// persistent composer chrome.
    public var visibleTodos: Plan? {
        guard let todos,
              todos.entries.contains(where: { $0.status != .completed }) else {
            return nil
        }
        return todos
    }

    /// Restores the per-session disclosure preference after controller
    /// creation or LRU eviction.
    public func restoreTodoDisclosure(isExpanded: Bool) {
        isTodosExpanded = isExpanded
    }

    // MARK: - Questions

    /// The question the composer renders as a picker: a real blocking agent
    /// question, or codex's client-side plan approval (below) when neither the
    /// server nor a tool drives it.
    public var activeQuestion: QuestionRequest? { pendingQuestion ?? planApprovalRequest }

    /// The blocking agent question the composer renders as a picker.
    public var pendingQuestion: QuestionRequest? { model?.pendingQuestion }

    public func answerQuestion(answers: [String: QuestionAnswerEntry]) async {
        guard !isResolvingQuestion else { return }
        isResolvingQuestion = true
        defer { isResolvingQuestion = false }
        // Codex's plan approval is a client-side prompt with no server question
        // to answer — resolve it by messaging the model, not via the server.
        if pendingPlanApproval {
            await resolvePlanApproval(answers)
            return
        }
        // Accepting Claude's ExitPlanMode approval ("Implement plan") also leaves
        // plan mode, so the agent implements in build mode and the composer
        // toggle reflects the move from planning to building. Switch first, then
        // release the held tool.
        if answers[QuestionRequest.exitPlanModeId]?.answers.first == QuestionRequest.implementPlanLabel,
           isPlanModeOn {
            await togglePlanMode()
        }
        await model?.answerQuestion(answers: answers)
    }

    public func cancelQuestion() async {
        guard !isResolvingQuestion else { return }
        isResolvingQuestion = true
        defer { isResolvingQuestion = false }
        // Dismissing codex's plan prompt just keeps planning: no message, back
        // to the composer.
        if pendingPlanApproval {
            pendingPlanApproval = false
            if let session = serverSession {
                try? await serverClient?.clearSessionPlanApproval(id: session.id)
            }
            return
        }
        await model?.cancelQuestion()
    }

    /// Opens one browser-extension setup destination without resolving the
    /// blocking agent question. These are utility actions, so the composer
    /// must remain mounted while Chrome or Finder opens.
    public func performBrowserExtensionSetupAction(_ action: String) async {
        guard let serverClient else { return }
        do {
            switch action {
            case "Open Extensions":
                _ = try await serverClient.openBrowserExtensionsPage()
            case "Show Folder":
                _ = try await serverClient.openBrowserExtensionFolder()
            case "Open Web Store":
                _ = try await serverClient.openBrowserExtensionWebStore()
            default:
                return
            }
        } catch {
            Log.server.error(
                "Failed to open browser extension setup destination: \(String(describing: error), privacy: .public)"
            )
        }
    }

    public func browserExtensionArchive() async throws -> URL {
        guard let serverClient else {
            throw CodevisorServerClientError.invalidResponse
        }
        return try await serverClient.browserExtensionArchive()
    }

    public func browserExtensionIcon() async throws -> URL {
        guard let serverClient else {
            throw CodevisorServerClientError.invalidResponse
        }
        return try await serverClient.browserExtensionIcon()
    }

    // MARK: - Codex plan approval

    /// Codex has no ExitPlanMode tool: when a plan-mode turn ends having
    /// proposed a plan, we surface the same "implement this plan?" picker as a
    /// client-side prompt. Answering it messages the model (there is no held
    /// tool to resolve) — mirroring codex CLI's approve = leave-plan-mode +
    /// "Implement the plan." user turn.
    public private(set) var pendingPlanApproval = false

    /// Only harnesses that propose plans without a blocking approval tool use
    /// this post-turn prompt (Claude's ExitPlanMode already drives its own).
    private var usesPostTurnPlanApproval: Bool {
        (connectedHarnessId ?? selectedHarnessId) == "codex"
    }

    /// The synthetic picker for the client-side plan approval, mirroring the
    /// server-built one Claude sends.
    private var planApprovalRequest: QuestionRequest? {
        guard pendingPlanApproval else { return nil }
        return QuestionRequest(
            questionId: "codex-plan-approval",
            questions: [QuestionSpec(
                id: QuestionRequest.exitPlanModeId,
                header: "Plan",
                question: "Ready to implement this plan?",
                options: [
                    QuestionOption(label: QuestionRequest.implementPlanLabel, description: "Start building"),
                    QuestionOption(label: QuestionRequest.keepPlanningLabel, description: "Keep refining in plan mode")
                ],
                allowsOther: false
            )]
        )
    }

    /// Fired at turn end: raise the plan prompt when a codex plan-mode turn
    /// proposed a plan.
    private func noteTurnEndedForPlanApproval() {
        guard usesPostTurnPlanApproval, isPlanModeOn, !pendingPlanApproval else { return }
        guard case let .assistant(message) = conversation.last,
              let plan = message.turn.planDocument, !plan.isEmpty else { return }
        pendingPlanApproval = true
    }

    private func resolvePlanApproval(_ answers: [String: QuestionAnswerEntry]) async {
        pendingPlanApproval = false
        if let session = serverSession {
            try? await serverClient?.clearSessionPlanApproval(id: session.id)
        }
        let entry = answers[QuestionRequest.exitPlanModeId]
        let note = (entry?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if entry?.answers.first == QuestionRequest.implementPlanLabel {
            // Approve: leave plan mode and tell the model to build. Codex has no
            // exit-plan tool, so this rides as a normal user message.
            if isPlanModeOn { await togglePlanMode() }
            userSendSignal &+= 1
            await model?.send(note.isEmpty ? "Implement the plan." : "Implement the plan.\n\n\(note)")
        } else if !note.isEmpty {
            // Keep planning, but a note is refinement feedback — send it so the
            // model iterates (still in plan mode).
            userSendSignal &+= 1
            await model?.send(note)
        }
        // Keep planning with no note: nothing to send; the composer returns.
    }

    /// Selectable config options: live when connected, otherwise the cached
    /// (stale) options for the selected harness with any pending edits applied.
    public var configOptions: [SessionConfigOption] {
        if let model, !model.configOptions.isEmpty || !isConnectingToHarness {
            return model.configOptions
        }
        guard let harnessId = selectedHarnessId else { return [] }
        let pendingConfig = pendingConfigByHarness[harnessId] ?? [:]
        return (configOptionsByHarness[harnessId]
            ?? configCache.options(forHarness: harnessId, onServer: project.serverId)).map { option in
            guard let pending = pendingConfig[option.id] else { return option }
            var updated = option
            updated.currentValue = pending
            return updated
        }
    }

    /// Categories folded into the combined model dropdown rather than shown
    /// as individual picker chips.
    private static let modelMenuCategories: Set<String> = [
        SessionConfigOption.Category.model,
        SessionConfigOption.Category.thoughtLevel,
        SessionConfigOption.Category.speed
    ]

    /// Config categories that follow the user between composers. Modes remain
    /// local to a chat; run location is remembered separately from harness
    /// configuration.
    private static let rememberedConfigCategories: Set<String> = [
        SessionConfigOption.Category.model,
        SessionConfigOption.Category.thoughtLevel,
        SessionConfigOption.Category.speed,
        SessionConfigOption.Category.modelConfig
    ]

    /// The model choice shown in the combined model dropdown.
    public var modelOption: SessionConfigOption? {
        configOptions.first { $0.category == SessionConfigOption.Category.model && !$0.options.isEmpty }
    }

    /// Thinking/reasoning controls shown in the combined model dropdown.
    /// Some agents expose more than one (for example, Thinking plus Effort).
    public var thoughtLevelOptions: [SessionConfigOption] {
        configOptions.filter { $0.category == SessionConfigOption.Category.thoughtLevel && !$0.options.isEmpty }
    }

    /// The speed (standard/fast) shown in the combined model dropdown; only
    /// present when the agent/model pair supports a fast tier.
    public var speedOption: SessionConfigOption? {
        configOptions.first { $0.category == SessionConfigOption.Category.speed && !$0.options.isEmpty }
    }

    public var hasModelMenu: Bool {
        modelOption != nil || !thoughtLevelOptions.isEmpty || speedOption != nil
    }

    /// Resumed chats intentionally avoid painting generic fresh-session
    /// defaults while their runtime metadata loads. Reserve the model picker's
    /// place with a spinner during that gap instead of popping it in later.
    public var isLoadingModelMenu: Bool {
        guard !hasModelMenu else { return false }
        if isConnecting || isConnectingToHarness { return true }
        // A draft with no spawned agent yet (new-chat page, deferred chats)
        // fetching harness capabilities: hold the model chip's slot with a
        // spinner too, instead of rendering nothing until options land.
        // Scoped to agent-less drafts so a connected harness that simply has
        // no model options can't spin forever on a stale preparation state.
        if serverSession?.agentSessionId?.isEmpty != false, model == nil,
           preparationState == .loading {
            return true
        }
        guard model == nil, serverSession?.agentSessionId?.isEmpty == false else { return false }
        if case .failed = status { return false }
        return true
    }

    /// The config options still shown as individual picker chips (model
    /// config, unknown categories), in a sensible order. Mode options are
    /// excluded entirely: the composer's plan toggle is the only mode control
    /// (everything else runs in the harness's full-access/build default).
    public var pickerOptions: [SessionConfigOption] {
        let order = [SessionConfigOption.Category.modelConfig]
        return configOptions
            .filter { option in
                !option.options.isEmpty
                    && !Self.modelMenuCategories.contains(option.category ?? "")
                    && option.category != SessionConfigOption.Category.mode
                    && option.id != "mode"
            }
            .sorted { left, right in
                let leftIndex = order.firstIndex(of: left.category ?? "") ?? 99
                let rightIndex = order.firstIndex(of: right.category ?? "") ?? 99
                if leftIndex == rightIndex { return left.name < right.name }
                return leftIndex < rightIndex
            }
    }

    public func setConfigOption(_ configId: String, _ value: String) async {
        guard !isConnectingToHarness else { return }
        let optionBeforeChange = configOptions.first { $0.id == configId }
        let previousValue = optionBeforeChange?.currentValue
        var accepted = true
        if let model {
            accepted = await model.setConfigOption(configId: configId, value: value)
            if let harnessId = connectedHarnessId {
                configCache.store(model.configOptions, forHarness: harnessId, onServer: project.serverId)
                configOptionsByHarness[harnessId] = model.configOptions
            }
        } else {
            // Not connected yet: remember it and apply on connect.
            if let harnessId = selectedHarnessId {
                pendingConfigByHarness[harnessId, default: [:]][configId] = value
                var options = configOptionsByHarness[harnessId]
                    ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
                if let index = options.firstIndex(where: { $0.id == configId }) {
                    options[index].currentValue = value
                    configOptionsByHarness[harnessId] = options
                }
            }
        }
        if accepted,
           optionBeforeChange?.category == SessionConfigOption.Category.model,
           previousValue != value {
            captureModelSelected(modelId: value, previousModelId: previousValue)
            configurationAdjustmentMessage = nil
            // The user just chose a model, so a "we swapped your model" notice
            // no longer describes the current state.
            model?.clearModelFallback()
        }
        // Explicit picker actions become the next composer's defaults
        // immediately, including in an unsent draft. Persist the resulting
        // authoritative option set so model-dependent effort/speed resets are
        // remembered too.
        if accepted,
           Self.rememberedConfigCategories.contains(optionBeforeChange?.category ?? ""),
           let harnessId = connectedHarnessId ?? selectedHarnessId {
            composerDefaults?.rememberConfigSelections(
                in: resolvedComposerDefaultsScope,
                harnessId: harnessId,
                configValues: rememberedConfigValues
            )
            composerDefaults?.rememberHarnessSelection(
                in: resolvedComposerDefaultsScope,
                harnessId: harnessId
            )
        }
    }

    // MARK: - Remembered composer defaults

    /// True until the first send creates the real session — the window where
    /// remembered defaults are seeded into pending config.
    private var isDraft: Bool { serverSession == nil && !hasSentFirst }

    /// Eagerly-created workspace chat records still behave like drafts until
    /// their first agent session exists. They need inherited configuration
    /// even though `serverSession` is already non-nil.
    private var acceptsNewChatDefaults: Bool {
        !hasSentFirst
            && resumeAgentSessionId?.isEmpty != false
            && serverSession?.agentSessionId?.isEmpty != false
    }

    private var resolvedComposerDefaultsScope: ComposerDefaultsStore.Scope {
        composerDefaultsScope ?? .newWorkspace(serverId: project.serverId)
    }

    /// Seeds a new-chat draft from the last explicit selections on this
    /// machine. Called once by `SessionStore` when a draft is made.
    public func applyComposerDefaults() {
        guard let composerDefaults, acceptsNewChatDefaults else { return }
        if let harnessId = composerDefaults.lastHarnessId(for: resolvedComposerDefaultsScope),
           !harnessId.isEmpty,
           harnesses.isEmpty || harnesses.contains(where: { $0.id == harnessId }) {
            selectedHarnessId = harnessId
        }
        seedRememberedConfig()
    }

    /// Stages the remembered config selections for the selected harness as
    /// pending edits so the pickers show them and the agent applies them on
    /// connect. Values are validated against the known option lists when
    /// available; unknown lists trust the stored values and let the live
    /// agent correct them.
    private func seedRememberedConfig() {
        guard let composerDefaults, let harnessId = selectedHarnessId else { return }
        let remembered = composerDefaults.configSelections(
            forHarness: harnessId,
            in: resolvedComposerDefaultsScope
        )
        guard !remembered.isEmpty else { return }
        var options = configOptionsByHarness[harnessId]
            ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
        guard !options.isEmpty else {
            pendingConfigByHarness[harnessId, default: [:]].merge(remembered) { current, _ in current }
            return
        }
        for (configId, value) in remembered {
            // A speed option can be absent until its remembered model is
            // restored. Keep it queued and validate it against the live agent
            // after the model change makes the option available.
            guard let index = options.firstIndex(where: { $0.id == configId }) else {
                if configId == "speed" {
                    pendingConfigByHarness[harnessId, default: [:]][configId] = value
                }
                continue
            }
            guard options[index].options.contains(where: { $0.value == value }) else { continue }
            let selectedValue = pendingConfigByHarness[harnessId]?[configId] ?? value
            pendingConfigByHarness[harnessId, default: [:]][configId] = selectedValue
            options[index].currentValue = selectedValue
        }
        configOptionsByHarness[harnessId] = options
    }

    /// Remembered config categories (model, reasoning, speed, model config)
    /// as currently selected — what composer memory captures.
    private var rememberedConfigValues: [String: String] {
        let values = configOptions
            .filter { Self.rememberedConfigCategories.contains($0.category ?? "") }
            .map { ($0.id, $0.currentValue) }
        return Dictionary(values) { _, last in last }
    }

    /// Captures this chat as the inheritance source for its scope. Workspace
    /// capture replaces the selected harness snapshot so values from a
    /// previously focused sibling cannot leak into the next chat.
    public func rememberCurrentComposerConfiguration() {
        guard let composerDefaults,
              let harnessId = connectedHarnessId ?? selectedHarnessId ?? serverSession?.harnessId,
              !harnessId.isEmpty else { return }
        switch resolvedComposerDefaultsScope {
        case let .newWorkspace(serverId):
            composerDefaults.rememberHarnessSelection(
                in: .newWorkspace(serverId: serverId),
                harnessId: harnessId
            )
            composerDefaults.rememberConfigSelections(
                in: .newWorkspace(serverId: serverId),
                harnessId: harnessId,
                configValues: rememberedConfigValues
            )
        case let .workspace(id, serverId):
            composerDefaults.rememberFocusedChat(
                workspaceId: id,
                serverId: serverId,
                harnessId: harnessId,
                configValues: rememberedConfigValues
            )
        }
    }

    /// A standalone draft becomes the first chat of a concrete workspace
    /// before its agent is connected. Snapshot its selected configuration
    /// into that workspace immediately so a sibling tab opened during setup
    /// inherits the same values.
    public func moveComposerDefaults(to scope: ComposerDefaultsStore.Scope) {
        composerDefaultsScope = scope
        rememberCurrentComposerConfiguration()
    }

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

    /// User-facing text for a refusal-driven model swap, with both model ids
    /// resolved to display names where the live model option still lists them.
    /// The original usually is not listed once the swap is sticky, so its raw
    /// id is the expected fallback rather than an error case.
    public var modelFallbackMessage: String? {
        guard let fallback = model?.modelFallback else { return nil }
        let names = configOptions.first {
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

    public func retrySessionFailure() async {
        if case .failed = status, hasExistingAgentSession {
            let failedModel = model
            model = nil
            failedModel?.shutdown()
            await retry()
        } else if let model {
            await model.retrySessionFailure()
        } else {
            await retry()
        }
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
            && configurationValidationState == .ready
            && (isConnected || selectedHarness != nil)
    }

    // MARK: - Attachments

    static public let maxAttachments = 10

    public func attachFileURLs(_ urls: [URL]) {
        for url in urls {
            attachFileURL(url)
        }
    }

    /// Stages one dropped/picked file. The bytes are read off the main
    /// thread so a large file or one on a slow network volume does not freeze
    /// the run loop.
    private func attachFileURL(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        let kind: Attachment.Kind = (type?.conforms(to: .image) ?? false) || mimeType.hasPrefix("image/")
            ? .image
            : .file
        Task { [weak self] in
            let result: (data: Data?, readError: String?) = await Task.detached(priority: .userInitiated) {
                do {
                    return (try Data(contentsOf: url), nil)
                } catch {
                    return (nil, String(describing: error))
                }
            }.value
            guard let self else { return }
            if let data = result.data {
                self.stageAttachment(name: url.lastPathComponent, mimeType: mimeType, kind: kind, data: data)
            } else {
                Log.attachments.error("attachment read failed for \(url.lastPathComponent, privacy: .public): \(result.readError ?? "unknown", privacy: .public)")
                self.stageAttachment(
                    name: url.lastPathComponent, mimeType: mimeType, kind: kind,
                    data: Data(),
                    failureMessage: "Couldn't read “\(url.lastPathComponent)”. Check that you have permission to open it, then try again."
                )
            }
        }
    }

    public func attachImageData(_ data: Data, suggestedName: String? = nil) {
        let name = suggestedName ?? "Pasted image \(Self.pastedImageFormatter.string(from: Date())).png"
        stageAttachment(name: name, mimeType: "image/png", kind: .image, data: data)
    }

    public func removeAttachment(id: UUID) {
        uploadTasks[id]?.cancel()
        uploadTasks[id] = nil
        composerAttachments.removeAll { $0.id == id }
    }

    public func retryAttachment(id: UUID) {
        guard let index = composerAttachments.firstIndex(where: { $0.id == id }),
              case .failed = composerAttachments[index].state else { return }
        composerAttachments[index].state = .uploading
        startUpload(composerAttachments[index])
    }

    /// Fetches stored attachment bytes through this session's server client —
    /// History thumbnails and Quick Look load through here so auth carries
    /// over for remote servers.
    public func fileData(id: String) async throws -> Data {
        guard let serverClient else { throw SessionControllerError.serverUnavailable }
        return try await serverClient.fileData(id: id)
    }

    private func stageAttachment(
        name: String, mimeType: String, kind: Attachment.Kind, data: Data,
        failureMessage: String? = nil
    ) {
        guard composerAttachments.count < Self.maxAttachments else {
            status = .failed("A message can carry at most \(Self.maxAttachments) attachments.")
            return
        }
        var attachment = ComposerAttachment(
            id: UUID(),
            name: name,
            mimeType: mimeType,
            kind: kind,
            localData: data,
            state: .uploading
        )
        if let failureMessage {
            attachment.state = .failed(failureMessage)
            composerAttachments.append(attachment)
            return
        }
        composerAttachments.append(attachment)
        startUpload(attachment)
    }

    private func startUpload(_ attachment: ComposerAttachment) {
        guard let serverClient else {
            setAttachmentState(attachment.id, .failed("Server unavailable"))
            return
        }
        uploadTasks[attachment.id] = Task { [weak self] in
            do {
                let metadata = try await serverClient.uploadFile(
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    data: attachment.localData
                )
                guard !Task.isCancelled else { return }
                self?.setAttachmentState(attachment.id, .uploaded(metadata.attachmentRef))
            } catch {
                guard !Task.isCancelled else { return }
                self?.setAttachmentState(attachment.id, .failed(serverErrorMessage(error)))
            }
            self?.uploadTasks[attachment.id] = nil
        }
    }

    private func setAttachmentState(_ id: UUID, _ state: ComposerAttachment.State) {
        guard let index = composerAttachments.firstIndex(where: { $0.id == id }) else { return }
        composerAttachments[index].state = state
    }

    /// Waits for in-flight uploads, then returns the attachments to send —
    /// nil (with a surfaced status) if any upload failed.
    private func collectAttachmentsForSend() async -> [Attachment]? {
        for task in uploadTasks.values {
            await task.value
        }
        var attachments: [Attachment] = []
        for staged in composerAttachments {
            switch staged.state {
            case let .uploaded(ref):
                attachments.append(ref.attachment)
            case .failed:
                status = .failed("An attachment failed to upload. Retry or remove it, then send again.")
                return nil
            case .uploading:
                // Unreachable: awaiting the tasks above settles every state.
                return nil
            }
        }
        return attachments
    }

    private static let pastedImageFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    // MARK: - Actions

    /// Loads the harness list for the picker from the server (cached
    /// capabilities first for instant display, then a live refresh). For a new
    /// chat the list honors the user's enabled set (falling back to all ready
    /// harnesses if they've disabled everything); a resumed session always
    /// keeps its own harness.
    public func prepare() async {
        guard let serverClient else {
            preparationState = .failed
            return
        }
        if seedFromCachedServerCapabilities() {
            preparationState = .ready
            Task { await self.prepareFromServerCapabilities(serverClient) }
            return
        }
        preparationState = .loading
        _ = await prepareFromServerCapabilities(serverClient)
    }

    /// Refreshes only the harness used by a resumed chat. This runs beside
    /// transcript/runtime connection and never gates the first history paint.
    /// The live resumed-session metadata remains authoritative; this snapshot
    /// supplies fresh picker definitions and the compatibility fallback for
    /// servers that do not yet return runtime metadata from `/connect`.
    public func prepareExistingSessionCapabilities() async {
        let harnessId = serverSession?.harnessId ?? selectedHarnessId ?? ""
        guard hasExistingAgentSession, let serverClient, !harnessId.isEmpty else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await serverClient.capabilities(
                cwd: sessionCwdURL.path,
                harnessId: harnessId
            )
            guard let capability = response.harnesses.first(where: { $0.harness.id == harnessId }) else {
                existingConfigurationError = "The chat's harness is unavailable."
                updateConfigurationValidationState()
                logExistingChatPhase("capabilities_missing", harnessId: harnessId, startedAt: startedAt)
                return
            }
            var validatedCapability = capability
            validatedCapability.configOptions = Self.configurationOptions(
                restoring: serverSession?.configSelections,
                from: capability.configOptions
            )
            // Deliberately NOT deriving `configurationAdjustmentMessage` here.
            // This is a throwaway fresh-harness inspection: it runs under the
            // harness's *active* account rather than the chat's bound one, its
            // model list is a best-effort race that yields an empty list on
            // timeout, and its effort/speed lists are derived from the
            // inspection's own default model. Any of those makes the chat's
            // saved selection look missing, and because this call beats the
            // runtime connect (which can cold-spawn the agent), the false
            // claim was what the user actually read. Only the resumed
            // runtime's own snapshot can answer "is this still available".
            configCache.store(validatedCapability, forServer: project.serverId)
            applyHarnessCapabilities([validatedCapability])
            // A late generic inspection must not leave its fresh-session
            // defaults in the fast cache after the actual resumed runtime won.
            if let model, let connectedHarnessId {
                configCache.store(
                    model.configOptions,
                    forHarness: connectedHarnessId,
                    onServer: project.serverId
                )
            }
            didLoadExistingHarnessCapabilities = true
            existingConfigurationError = nil
            updateConfigurationValidationState()
            logExistingChatPhase("capabilities_ready", harnessId: harnessId, startedAt: startedAt)
        } catch {
            existingConfigurationError = serverErrorMessage(error)
            updateConfigurationValidationState()
            logExistingChatPhase("capabilities_failed", harnessId: harnessId, startedAt: startedAt)
        }
    }

    public func retryExistingSessionCapabilities() async {
        didLoadExistingHarnessCapabilities = false
        existingConfigurationError = nil
        updateConfigurationValidationState()
        await prepareExistingSessionCapabilities()
    }

    public func dismissConfigurationAdjustment() {
        configurationAdjustmentMessage = nil
    }

    /// Reloads the authoritative harness catalog after authentication or
    /// enablement changes. Unlike `prepare()`, this deliberately bypasses the
    /// stale cache because the caller is responding to an explicit mutation.
    public func refreshHarnessCapabilities() async {
        guard let serverClient else {
            preparationState = .failed
            return
        }
        _ = await prepareFromServerCapabilities(serverClient)
    }

    /// How long the eager connect quietly waits on an unreachable server
    /// before softening the loading copy ("taking longer than usual").
    private static let serverWaitSlowThreshold: Duration = .seconds(5)
    /// How long an unreachable server gets before the wait is treated as a
    /// real failure (error banner with the Restart remedy).
    private static let serverWaitFailureThreshold: Duration = .seconds(10)
    private static let serverWaitRetryInterval: Duration = .milliseconds(500)

    /// Eagerly connects the selected harness (without sending) so model and
    /// reasoning config options are available in the composer before the first
    /// message. Safe to call repeatedly.
    ///
    /// A server that refuses connections here is usually just booting — after
    /// an update the app relaunches before its managed server is listening
    /// again. Unreachable errors therefore retry behind a calm loading state
    /// (softened past 5s) and only surface the failure banner — with its
    /// Restart remedy — after 10s without contact.
    public func connectIfNeeded() async {
        // The connect attempt is CONTROLLER-owned, not a child of the view
        // task that called this. Controllers are cached beyond any single
        // mount, and the first open of a remotely created chat re-hosts its
        // pane mid-connect (the container's workspace/tab fix-up bumps the
        // layout): a view-owned attempt died with that remount — after
        // painting the transcript and then UN-publishing it in the runtime
        // catch — while the remounted view's retry bounced off the stale
        // `.connecting` status below, leaving the chat permanently empty.
        // Joining the surviving attempt fixes both halves of that race.
        if let attempt = connectAttempt {
            await attempt.value
            return
        }
        guard model == nil, !isConnecting, let serverSession else { return }
        // A worktree draft has no cwd until the worktree is created on first
        // send; connecting now would pin the agent to the project folder.
        guard !wantsNewWorktree || sessionCwdOverride != nil else { return }
        let persistedHarnessId = serverSession.harnessId
        let harnessId = persistedHarnessId.isEmpty ? selectedHarness?.id : persistedHarnessId
        guard let harnessId, !harnessId.isEmpty else { return }
        let harnessName = selectedHarness?.name ?? harnessId
        let attempt = Task { await self.runConnectAttempt(harnessId: harnessId, harnessName: harnessName) }
        connectAttempt = attempt
        await attempt.value
    }

    private func runConnectAttempt(harnessId: String, harnessName: String) async {
        defer { connectAttempt = nil }
        status = .connecting("Starting \(harnessName)…")
        defer { serverWaitMessage = nil }
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            do {
                model = try await connect(harnessId: harnessId)
                status = .idle
                return
            } catch {
                // View remounts no longer cancel this controller-owned
                // attempt; cancellation now means an explicit supersede
                // (`reconnect()` tearing down a stale attempt) and is
                // lifecycle noise, not a failure. Reset to `.idle` so the
                // successor passes the `!isConnecting` guard — leaving
                // `.connecting` would wedge the controller forever (and
                // `SessionStore` would never evict it, since `.connecting`
                // counts as running).
                guard !isTaskCancellation(error) else {
                    if case .connecting = status { status = .idle }
                    return
                }
                let message = serverErrorMessage(error)
                let elapsed = clock.now - start
                guard message == serverUnreachableErrorMessage,
                      elapsed < Self.serverWaitFailureThreshold else {
                    if hasExistingAgentSession {
                        didFinishExistingRuntimeConfiguration = true
                        existingConfigurationError = message
                        updateConfigurationValidationState()
                        if let sessionId = serverSession?.id {
                            finishInitialHistoryLoading(
                                sessionId: sessionId,
                                outcome: "failed"
                            )
                        }
                    }
                    status = .failed(message)
                    return
                }
                serverWaitMessage = elapsed < Self.serverWaitSlowThreshold
                    ? "Connecting to the server..."
                    : "Still connecting... this is taking longer than usual."
                try? await Task.sleep(for: Self.serverWaitRetryInterval)
                guard !Task.isCancelled else {
                    if case .connecting = status { status = .idle }
                    return
                }
            }
        }
    }

    /// Selects a different harness (user action) and reconnects.
    public func selectHarness(_ id: String) async {
        guard id != selectedHarnessId else { return }
        let previousHarnessId = selectedHarnessId
        selectedHarnessId = id
        captureHarnessSelected(harnessId: id, previousHarnessId: previousHarnessId)
        if acceptsNewChatDefaults {
            // Start the new harness from its own remembered selections rather
            // than pending edits made under the previous harness.
            seedRememberedConfig()
        }
        composerDefaults?.rememberHarnessSelection(
            in: resolvedComposerDefaultsScope,
            harnessId: id
        )
        if var serverSession {
            serverSession.harnessId = id
            self.serverSession = serverSession
        }
        await reconnect()
    }

    /// Changes the project (new-chat picker) and reconnects.
    public func selectProject(_ project: Project) async {
        guard project.id != self.project.id else { return }
        self.project = project
        // A worktree kept from a reverted first send belongs to the old
        // project; the new project gets its own on the next send.
        sessionCwdOverride = nil
        worktreeName = nil
        if seedFromCachedServerCapabilities() {
            preparationState = .ready
        }
        await reconnect()
    }

    /// Tears down any connection and reconnects — used when the harness or
    /// project changes on the new-chat page.
    public func reconnect() async {
        // Supersede a controller-owned eager connect explicitly: cancel it and
        // wait for it to settle so its failure handling cannot clobber the
        // fresh attempt's status/model below.
        if let attempt = connectAttempt {
            attempt.cancel()
            await attempt.value
        }
        model = nil
        status = .idle
        await connectIfNeeded()
    }

    /// Sends the composer text, transitioning immediately into the transcript.
    /// Worktree and agent setup render after the optimistic first user message.
    public func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !composerAttachments.isEmpty,
              !isConnecting,
              configurationValidationState == .ready,
              !isSubmitting else { return }
        showsNewChatAfterSetupFailure = false
        status = .idle
        // Ask at the first moment notifications become useful instead of at
        // launch: the user just started work that may finish while they are in
        // another app. The task is intentionally nonblocking for the send.
        if let notificationDelivery {
            Task { await notificationDelivery.prepareAuthorizationIfNeeded() }
        }
        isSubmitting = true

        // Settle eager uploads first; a failed attachment blocks the send with
        // an inline status instead of silently dropping the file.
        guard let attachments = await collectAttachmentsForSend() else {
            isSubmitting = false
            return
        }
        let outgoingMessage = UserMessage(text: text, attachments: attachments)
        let shouldAnimateTranscriptSend = !isSending
        // Sending expresses "take me to the newest content": the transcript
        // re-pins only once the send is certain to proceed.
        userSendSignal &+= 1

        // Publish one client-owned optimistic row together with its animation
        // request. A connected model will adopt this exact id synchronously;
        // a model-less send keeps the same row visible while setup catches up.
        // In either case the transcript never observes a request without its
        // target, so native host readiness adds no extra send-state round trip.
        if shouldAnimateTranscriptSend {
            pendingUserMessage = outgoingMessage
            requestUserSendAnimation(for: outgoingMessage.id)
        }

        // A brand-new chat renders its pre-chat steps as setup sections; a
        // resumed session's transcript shouldn't grow one retroactively.
        let showsSetupPhases =
            (pendingNewChatAnalytics || (!hasSentFirst && onFirstSend != nil))
                && resumeAgentSessionId == nil
        // Clear the durable draft before mounting any first-send destination.
        // The source UIKit editor keeps its already-rendered pixels until the
        // transition surface covers it, while every newly mounted composer
        // starts empty. Publishing this after `onFirstSend` let the promotion
        // composer briefly rebuild with stale text, producing the visible
        // empty -> sent text -> empty pop.
        let staged = composerAttachments
        composerText = ""
        composerAttachments = []
        // Materialize the durable session before setup so the workspace and
        // pane keep a stable identity even if setup fails.
        if !hasSentFirst {
            hasSentFirst = true
            if onFirstSend != nil {
                pendingNewChatAnalytics = true
            }
            onFirstSend?()
            onFirstSend = nil
        }
        isSubmitting = false

        func restoreComposer() {
            composerText = text
            composerAttachments = staged
            pendingUserMessage = nil
            cancelUserSendAnimation(for: outgoingMessage.id)
        }

        // Materialize the worktree before the agent exists, so it is born
        // with the worktree cwd. Progress (including checkout-hook output)
        // streams into the "Setting up worktree…" section.
        if wantsNewWorktree, sessionCwdOverride == nil {
            if let failure = await createWorktree(showsSetupPhase: showsSetupPhases) {
                restoreComposer()
                handleSetupFailure(failure, returnsToNewChat: showsSetupPhases)
                return
            }
        }

        if let model {
            await model.send(outgoingMessage)
            if pendingUserMessage?.id == outgoingMessage.id {
                pendingUserMessage = nil
            }
            return
        }

        guard let harness = selectedHarness else {
            let message = "No agent is installed. Install Claude Code or Codex and try again."
            restoreComposer()
            handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
            return
        }
        status = .connecting("Starting \(harness.name)…")
        if showsSetupPhases { beginSetupPhase(.startingAgent(named: harness.name)) }
        do {
            let model = try await connect(harnessId: harness.id)
            self.model = model
            setupPhases.removeAll { $0.id == SessionSetupPhase.agentPhaseId }
            status = .idle
            await model.send(outgoingMessage)
            if pendingUserMessage?.id == outgoingMessage.id {
                pendingUserMessage = nil
            }
        } catch {
            let message = serverErrorMessage(error)
            restoreComposer()
            handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
        }
    }

    private func requestUserSendAnimation(for messageID: UUID) {
        userSendAnimationRequest = userSendAnimationCoordinator.issue(for: messageID)
    }

    /// Called by a native transcript only after the target row is mounted and
    /// ready to start its animation. The coordinator, rather than the view,
    /// owns consumption so remounting cannot replay the request.
    public func claimUserSendAnimation(_ request: UserSendAnimationRequest) -> Bool {
        userSendAnimationCoordinator.claim(request)
    }

    private func cancelUserSendAnimation(for messageID: UUID) {
        guard let request = userSendAnimationRequest, request.messageID == messageID else { return }
        userSendAnimationCoordinator.cancel(request)
        userSendAnimationRequest = nil
    }

    /// Continues the failed response in place. Automatic retries remain
    /// provider-owned; this explicit recovery starts a new assistant attempt
    /// under the original user message without duplicating that message.
    public func retryTurn(_ assistantID: UUID) async {
        guard let model, !model.isSending, !isConnecting, !isSubmitting else { return }
        guard let assistantIndex = model.conversation.firstIndex(where: { item in
            if case let .assistant(message) = item { return message.id == assistantID }
            return false
        }) else { return }
        guard let prompt = model.conversation[..<assistantIndex].reversed().compactMap({ item in
            if case let .user(message) = item { return message }
            return nil
        }).first else { return }
        await model.retryResponse(to: prompt)
    }

    /// Asks the server to create a git worktree for this draft. The server
    /// owns the fixed location (~/codevisor/{projectId}/{name}) and picks a
    /// random memorable name; the app never computes either. The worktree id
    /// is generated client-side so the server's `worktree.setup` events (git
    /// output, checkout hooks, failures) can be followed live into the setup
    /// section while the request is in flight. Returns the failure message on
    /// error (nil on success); the caller either continues the transcript
    /// transition or restores New Chat.
    private func createWorktree(showsSetupPhase: Bool) async -> String? {
        guard let serverClient else {
            return "Worktrees need the Codevisor server. Start it and try again."
        }
        let worktreeId = UUID().uuidString.lowercased()
        if showsSetupPhase { beginSetupPhase(.worktree()) }
        status = .connecting("Setting up worktree…")
        // Best-effort live tail: the WebSocket usually opens well before git
        // (and any long checkout hooks) produce output. Terminal state comes
        // from the HTTP response, not from these events.
        let follow = Task { [weak self] in
            do {
                for try await envelope in serverClient.eventStream(
                    since: ServerSessionTransport.liveOnlyEventCursor
                ) {
                    guard case let .log(stream, line) = WorktreeSetupEvent.from(
                        envelope, worktreeId: worktreeId
                    ) else { continue }
                    self?.mutateSetupPhase(id: SessionSetupPhase.worktreePhaseId) {
                        $0.appendLog(stream: stream, line: line)
                    }
                }
            } catch {
                // The stream is cosmetic; a drop just stops the live tail.
                Log.session.debug("worktree setup log tail dropped: \(String(describing: error), privacy: .public)")
            }
        }
        defer { follow.cancel() }
        do {
            let worktree = try await serverClient.createWorktree(
                projectId: project.id,
                id: worktreeId,
                name: nil
            )
            sessionCwdOverride = worktree.path
            worktreeName = worktree.name
            // The session record was registered before the worktree existed;
            // carry the name/cwd onto it so the first connect (and terminals)
            // run in the worktree.
            if var session = serverSession {
                session.worktreeName = worktree.name
                session.cwd = worktree.path
                serverSession = session
            }
            onWorktreeCreated?(worktree)
            mutateSetupPhase(id: SessionSetupPhase.worktreePhaseId) { $0.succeed() }
            status = .idle
            return nil
        } catch let CodevisorServerClientError.httpStatus(_, message) {
            return WorktreeCreator.failureMessage(from: message)
        } catch {
            return serverErrorMessage(error)
        }
    }

    /// Failed first-send setup returns to the centered composer with its prompt
    /// restored. Existing-session failures remain in the transcript.
    private func handleSetupFailure(_ message: String, returnsToNewChat: Bool) {
        if returnsToNewChat {
            setupPhases.removeAll()
            // Restore the original draft lifecycle so every composer field is
            // persisted again while the user edits or retries. The durable
            // session remains registered; only this controller's draft-facing
            // state is reset.
            hasSentFirst = false
            pendingNewChatAnalytics = false
            showsNewChatAfterSetupFailure = true
            status = .failed(message)
            onSetupFailed?()
            onSetupFailed = nil
            return
        }
        status = .failed(message)
    }

    private func beginSetupPhase(_ phase: SessionSetupPhase) {
        setupPhases.removeAll { $0.id == phase.id }
        setupPhases.append(phase)
    }

    private func mutateSetupPhase(id: String, _ transform: (inout SessionSetupPhase) -> Void) {
        guard let index = setupPhases.firstIndex(where: { $0.id == id }) else { return }
        transform(&setupPhases[index])
    }

    public func stop() async {
        await model?.cancel()
    }

    public func updateQueuedPrompt(id: String, text: String) async {
        await model?.updateQueuedPrompt(id: id, text: text)
    }

    public func deleteQueuedPrompt(id: String) async {
        await model?.deleteQueuedPrompt(id: id)
    }

    public func setMode(_ modeId: String) async {
        if let model {
            await model.setMode(modeId)
        } else {
            pendingModeId = modeId
        }
    }

    // MARK: - Plan mode

    /// How plan mode is controlled for the selected harness. ACP has no plan
    /// capability flag (modes only arrive with `session/new`), so support is
    /// detected by inspecting what the harness exposes: a session mode mapped
    /// onto the canonical plan vocabulary, or — for harnesses like OpenCode
    /// that ship modes as a config select instead of ACP session modes — a
    /// mode-category config option with a plan-ish value.
    private enum PlanControl {
        case sessionMode(planId: String, buildId: String)
        case configOption(optionId: String, planValue: String, buildValue: String)
    }

    private var planControl: PlanControl? {
        if let modeState,
           let plan = modeState.availableModes.first(where: { $0.canonicalMode == .plan }),
           let build = modeState.availableModes.first(where: { $0.canonicalMode == .fullAccess })
               ?? modeState.availableModes.first(where: { $0.canonicalMode != .plan }) {
            return .sessionMode(planId: plan.id, buildId: build.id)
        }
        if let option = modeConfigOption,
           let plan = option.options.first(where: { Self.matches("^plan", $0.value, $0.name) }),
           let build = option.options.first(where: { Self.matches("bypass|full[-_ ]?access|yolo", $0.value, $0.name) })
               ?? option.options.first(where: { $0.value != plan.value }) {
            return .configOption(optionId: option.id, planValue: plan.value, buildValue: build.value)
        }
        return nil
    }

    /// The mode-category config select, for harnesses without ACP session
    /// modes (e.g. OpenCode's build/plan). Hidden from the picker chips and
    /// driven by the plan toggle instead.
    private var modeConfigOption: SessionConfigOption? {
        configOptions.first { $0.category == SessionConfigOption.Category.mode || $0.id == "mode" }
    }

    /// Mirrors the server's canonical-mode patterns (agent-runtime acp.ts) so
    /// the app and server recognize the same plan/full-access spellings.
    private static func matches(_ pattern: String, _ candidates: String...) -> Bool {
        candidates.contains {
            $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Whether the composer shows the plan toggle at all — needs a plan mode
    /// and a build/full-access mode to come back to.
    public var hasPlanMode: Bool { planControl != nil }

    public var isPlanModeOn: Bool {
        if let pendingPlanModeOn { return pendingPlanModeOn }
        switch planControl {
        case let .sessionMode(planId, _):
            return modeState?.currentModeId == planId
        case let .configOption(optionId, planValue, _):
            return configOptions.first { $0.id == optionId }?.currentValue == planValue
        case nil:
            return false
        }
    }

    public var isPlanModeUpdatePending: Bool { pendingPlanModeOn != nil }

    public func togglePlanMode() async {
        // The button is disabled while pending too, but keep the guard here so
        // multiple click tasks queued before SwiftUI redraws cannot submit the
        // same transition more than once.
        guard pendingPlanModeOn == nil, let planControl else { return }
        let targetIsOn = !isPlanModeOn
        // Plan and goal are mutually exclusive: entering plan mode disarms
        // the goal composer.
        if targetIsOn, isGoalComposerArmed {
            exitGoalComposer()
        }
        pendingPlanModeOn = targetIsOn
        defer { pendingPlanModeOn = nil }

        switch planControl {
        case let .sessionMode(planId, buildId):
            await setMode(targetIsOn ? planId : buildId)
        case let .configOption(optionId, planValue, buildValue):
            await setConfigOption(optionId, targetIsOn ? planValue : buildValue)
        }
    }

    public func retry() async {
        status = .idle
        if hasExistingAgentSession {
            if model == nil {
                didFinishExistingRuntimeConfiguration = false
                didLoadExistingRuntimeConfiguration = false
            }
            didLoadExistingHarnessCapabilities = false
            existingConfigurationError = nil
            updateConfigurationValidationState()
            async let capabilities: Void = prepareExistingSessionCapabilities()
            await connectIfNeeded()
            await capabilities
        } else {
            await prepare()
        }
    }

    // MARK: - Connection

    private func connect(harnessId: String) async throws -> SessionModel {
        guard let serverClient, var serverSession else {
            throw SessionControllerError.serverUnavailable
        }
        return try await connectServerSession(
            harnessId: harnessId,
            serverClient: serverClient,
            session: &serverSession
        )
    }

    private func connectServerSession(
        harnessId: String,
        serverClient: any CodevisorServerClienting,
        session: inout ChatSession
    ) async throws -> SessionModel {
        if session.harnessId.isEmpty {
            session.harnessId = harnessId
        }
        if session.agentSessionId == nil, let resumeAgentSessionId {
            session.agentSessionId = resumeAgentSessionId
        }
        let loadsExistingHistory = session.agentSessionId?.isEmpty == false
        if loadsExistingHistory {
            isLoadingInitialHistory = true
            initialHistoryLoadStartedAt = initialHistoryLoadStartedAt
                ?? ProcessInfo.processInfo.systemUptime
        }
        defer {
            if loadsExistingHistory {
                finishInitialHistoryLoading(sessionId: session.id, outcome: "failed")
            }
        }

        // One round-trip replaces the discrete listProjects → upsertProject →
        // listSessions → create/update → transcript sequence: the server
        // ensures both records exist (creating the project only when missing —
        // this controller's copy is a snapshot from when the draft was
        // created, and pushing it used to revert changes made in the
        // meantime, e.g. un-archiving) and returns the first transcript page
        // for an instant paint. Older servers lack the endpoint (nil) and
        // keep the discrete path; loadHistory then fetches the page itself.
        var preloadedTranscript: ServerTranscriptPage?
        let workspaceId: UUID? = switch resolvedComposerDefaultsScope {
        case let .workspace(id, _): id
        case .newWorkspace: nil
        }
        if let opened = try await serverClient.openSession(
            session,
            project: project,
            workspaceId: workspaceId,
            transcriptLimit: SessionModel.initialTranscriptPageSize
        ) {
            session = try opened.session.chatSession()
            preloadedTranscript = opened.transcript
        } else {
            let remoteProjects = try await serverClient.listProjects()
            if !remoteProjects.contains(where: { UUID(uuidString: $0.id) == project.id }) {
                _ = try await serverClient.upsertProject(project)
            }
            let remoteSession = try await serverClient.upsertSession(
                session,
                workspaceId: workspaceId
            )
            session = try remoteSession.chatSession()
        }
        self.serverSession = session

        connectedHarnessId = harnessId
        if let agentSessionId = session.agentSessionId {
            connectedAgentSessionId = agentSessionId
            onAgentSessionCreated?(agentSessionId)
        }

        // Start the runtime connect without blocking on it: for a resumed
        // thread this can cold-spawn the agent process server-side, which
        // takes multiple seconds on the first open after a server start. The
        // transcript reads straight from the server database and needs no
        // agent, so history loads — and paints — in parallel. The metadata is
        // awaited below, before anything runtime-dependent runs.
        let sessionId = session.id
        let runtimeConnectStartedAt = ProcessInfo.processInfo.systemUptime
        let runtimeConnect: Task<ServerSessionRuntimeMetadata?, Error>? =
            session.agentSessionId?.isEmpty == false
                ? Task { try await serverClient.connectSession(id: sessionId) }
                : nil

        let transport = ServerSessionTransport(client: serverClient, sessionId: session.id)
        // Paint the persisted selections over cached option definitions while
        // the live runtime validates them. The runtime snapshot below remains
        // authoritative and replaces removed models/options before Send is
        // enabled.
        let initialConfigOptions = configOptionsByHarness[harnessId]
            ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
        let model = SessionModel(
            serverTransport: transport,
            sessionId: session.id.uuidString,
            modeState: modeStateByHarness[harnessId],
            configOptions: initialConfigOptions
        )
        model.onTurnEnded = { [weak self, weak model] in
            if let model { self?.captureTurnEnded(model) }
            self?.noteTurnEndedForPlanApproval()
            self?.onTurnEnded?()
        }
        model.onRuntimeStateChanged = { [weak self] in
            self?.onRuntimeStateChanged?()
        }
        model.onGoalChanged = { [weak self] in
            self?.onGoalChanged?()
        }
        model.onPromptAccepted = { [weak self, weak model] attachmentCount, isQueued in
            self?.configurationAdjustmentMessage = nil
            self?.captureMessageSent(model: model, attachmentCount: attachmentCount, isQueued: isQueued)
        }
        model.onLocalUserMessageAppended = { [weak self] messageID in
            guard self?.pendingUserMessage?.id == messageID else { return }
            self?.pendingUserMessage = nil
        }
        model.onQueuedPromptPromoted = { [weak self] messageID in
            guard let messageID else { return }
            self?.requestUserSendAnimation(for: messageID)
        }
        model.onQueuedPromptsChanged = { [weak self] in
            self?.onQueuedPromptsChanged?()
        }
        model.onActionRequired = { [weak self] in
            self?.onActionRequired?()
        }
        model.onPlanApprovalChanged = { [weak self] required in
            self?.pendingPlanApproval = required
        }
        // Negotiate the canonical transcript + session-scoped event stream
        // for every server-backed model, including a brand-new empty chat.
        // Skipping this on first send leaves `usesPaginatedHistory` false, so
        // SessionModel falls back to the global compatibility stream. Current
        // servers deliberately exclude session runtime traffic from that
        // stream, which means the answer is persisted but its chunks and
        // terminal event never reach the live UI. Older servers still fall
        // back inside loadHistory() when the transcript endpoint returns 404.
        await model.loadHistoryForInitialDisplay(
            preloaded: preloadedTranscript.map(transport.historyPage(from:))
        )
        pendingPlanApproval = model.pendingPlanApproval
        if loadsExistingHistory {
            finishInitialHistoryLoading(sessionId: session.id, outcome: "ready")
        }
        analyticsUsageBaseline = model.usage

        // Publish the model as soon as history is loaded so an established
        // transcript paints while the agent is still spawning — but never
        // during pre-chat setup. A setup failure must leave no half-connected
        // model behind for Retry to mistake for a ready conversation.
        if setupPhases.isEmpty, self.model == nil {
            self.model = model
        }

        // Capability discovery describes a fresh harness session. A resumed
        // thread can have a different current model and model-specific effort
        // list, so let the loaded runtime replace the generic/cache snapshot.
        // (Stream events that arrive after this still overwrite as usual.)
        do {
            if let runtimeConnect {
                let metadata = try await withTaskCancellationHandler(
                    operation: { try await runtimeConnect.value },
                    onCancel: { runtimeConnect.cancel() }
                )
                if let metadata {
                    if !metadata.configOptions.isEmpty {
                        configOptionsByHarness[harnessId] = metadata.configOptions
                    }
                    if let modes = metadata.modes {
                        modeStateByHarness[harnessId] = modes
                    }
                    if let supportsGoals = metadata.supportsGoals {
                        supportsGoalsByHarness[harnessId] = supportsGoals
                    }
                    // Only a populated snapshot can be compared against: an
                    // empty option list would make every saved key look lost.
                    if !metadata.configOptions.isEmpty {
                        configurationAdjustmentMessage = Self.configurationAdjustmentMessage(
                            saved: session.configSelections,
                            validated: metadata.configOptions
                        )
                    }
                    didLoadExistingRuntimeConfiguration = true
                    model.applyRuntimeMetadata(
                        modeState: metadata.modes,
                        configOptions: metadata.configOptions
                    )
                }
                logExistingChatPhase(
                    "runtime_ready",
                    harnessId: harnessId,
                    startedAt: runtimeConnectStartedAt
                )
            }
            didFinishExistingRuntimeConfiguration = runtimeConnect != nil
            updateConfigurationValidationState()
        } catch {
            logExistingChatPhase(
                "runtime_failed",
                harnessId: harnessId,
                startedAt: runtimeConnectStartedAt
            )
            didFinishExistingRuntimeConfiguration = runtimeConnect != nil
            let message = serverErrorMessage(error)
            existingConfigurationError = message
            updateConfigurationValidationState()
            // History is durable and useful even when the live harness cannot
            // be restored. Keep the loaded model published so reopening a chat
            // never replaces its transcript with an empty error screen.
            model.recordSessionFailure(
                message,
                requiresHarnessAuthentication: message.localizedCaseInsensitiveContains(
                    "signed-in harness account"
                )
            )
            if self.model == nil { self.model = model }
            throw error
        }

        if let pendingModeId {
            await model.setMode(pendingModeId)
        }
        pendingModeId = nil

        // Model changes can replace the model-specific thinking and speed
        // options. Apply dependent selections afterward so a remembered fast
        // tier is available by the time it is restored.
        let pendingConfig = pendingConfigByHarness[harnessId] ?? [:]
        let optionCategories = Dictionary(
            uniqueKeysWithValues: model.configOptions.map { ($0.id, $0.category ?? "") }
        )
        let categoryOrder = [
            SessionConfigOption.Category.model: 0,
            SessionConfigOption.Category.thoughtLevel: 1,
            SessionConfigOption.Category.speed: 2
        ]
        // Cached options can disappear after an agent update or a model
        // change. Never replay a stale selection the runtime no longer
        // advertises (especially a hidden model-specific control).
        let supportedPendingConfig = pendingConfig.filter { optionCategories[$0.key] != nil }
        let orderedPendingConfig = supportedPendingConfig.sorted { left, right in
            func priority(_ configId: String) -> Int {
                if configId == "model" { return 0 }
                if configId == "speed" { return 2 }
                return categoryOrder[optionCategories[configId] ?? ""] ?? 99
            }
            let leftPriority = priority(left.key)
            let rightPriority = priority(right.key)
            if leftPriority == rightPriority { return left.key < right.key }
            return leftPriority < rightPriority
        }
        for (configId, value) in orderedPendingConfig {
            await model.setConfigOption(configId: configId, value: value)
        }
        pendingConfigByHarness[harnessId] = nil

        captureChatCreatedIfNeeded(model: model, harnessId: harnessId)
        await applyPendingGoal(to: model)

        configCache.store(model.configOptions, forHarness: harnessId, onServer: project.serverId)
        configOptionsByHarness[harnessId] = model.configOptions

        // This connect created the agent session (there was no id to resume
        // when it started), so there is no prior runtime configuration to
        // validate — the just-created runtime is authoritative and its config
        // was written by the replay above. Settle the flags so any later
        // recompute (a mid-connect `session.updated` refresh, a pane remount
        // re-running `prepareExistingSessionCapabilities`) resolves to
        // `.ready` instead of wedging the composer in `.connecting`.
        if runtimeConnect == nil {
            didLoadExistingRuntimeConfiguration = true
            didFinishExistingRuntimeConfiguration = true
            updateConfigurationValidationState()
        }
        return model
    }

    static func configurationAdjustmentMessage(
        saved: [String: String]?,
        validated: [SessionConfigOption]
    ) -> String? {
        guard let saved, !saved.isEmpty else { return nil }
        // An option the snapshot does not advertise at all is not evidence of
        // loss: several (`speed`, model-specific effort tiers) exist only for
        // certain models, so their absence is routine. Only an option that is
        // still present AND now reports a different value means the saved
        // selection could not be restored.
        let changed = saved.compactMap { configId, previousValue -> (String, SessionConfigOption)? in
            guard let option = validated.first(where: { $0.id == configId }),
                  option.currentValue != previousValue
            else { return nil }
            return (previousValue, option)
        }
        guard !changed.isEmpty else { return nil }
        if let (previousValue, model) = changed.first(where: {
            $0.1.category == SessionConfigOption.Category.model || $0.1.id == "model"
        }) {
            // `configSelections` persists values, not names. Resolve the display
            // name when the value is still listed (a plain switch); a genuinely
            // withdrawn model leaves only its raw value to show.
            let previousName = model.options.first { $0.value == previousValue }?.name ?? previousValue
            return "\(previousName) is no longer available. Using \(model.currentName)."
        }
        return "Some saved settings are no longer available. Current harness defaults are being used."
    }

    /// A capability inspection represents a fresh session, so its
    /// `currentValue`s are defaults. Preserve persisted values only when the
    /// freshly inspected option list still advertises them; removed values
    /// deliberately fall back to the harness default.
    private static func configurationOptions(
        restoring saved: [String: String]?,
        from inspected: [SessionConfigOption]
    ) -> [SessionConfigOption] {
        guard let saved, !saved.isEmpty else { return inspected }
        var restored = inspected
        for (configId, previousValue) in saved {
            guard let index = restored.firstIndex(where: { $0.id == configId }),
                  restored[index].options.contains(where: { $0.value == previousValue }) else { continue }
            restored[index].currentValue = previousValue
        }
        return restored
    }

    private func finishInitialHistoryLoading(sessionId: UUID, outcome: String) {
        guard isLoadingInitialHistory else { return }
        let startedAt = initialHistoryLoadStartedAt ?? ProcessInfo.processInfo.systemUptime
        isLoadingInitialHistory = false
        initialHistoryLoadStartedAt = nil
        let durationMs = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded())
        Log.session.info(
            "existing_chat_history phase=\(outcome, privacy: .public) session_id=\(sessionId.uuidString, privacy: .public) duration_ms=\(durationMs)"
        )
    }

    private func logExistingChatPhase(
        _ phase: String,
        harnessId: String,
        startedAt: TimeInterval
    ) {
        let durationMs = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded())
        Log.session.info(
            "existing_chat_load phase=\(phase, privacy: .public) harness_id=\(harnessId, privacy: .public) duration_ms=\(durationMs)"
        )
    }

    // MARK: - Analytics

    private func captureChatCreatedIfNeeded(model: SessionModel, harnessId: String) {
        guard pendingNewChatAnalytics else { return }
        pendingNewChatAnalytics = false
        var properties = analyticsSessionProperties(model: model)
        properties["harness_id"] = .string(harnessId)
        properties["uses_worktree"] = .boolean(serverSession?.worktreeName != nil)
        properties["client"] = .string(project.serverId == "local" ? "local" : "remote")
        AnalyticsClient.shared.capture(.chatCreated, properties: properties)
    }

    private func captureMessageSent(model: SessionModel?, attachmentCount: Int, isQueued: Bool) {
        var properties = analyticsSessionProperties(model: model)
        properties["attachment_count"] = .integer(attachmentCount)
        properties["is_queued"] = .boolean(isQueued)
        AnalyticsClient.shared.capture(.messageSent, properties: properties)
    }

    private func captureModelSelected(modelId: String, previousModelId: String?) {
        var properties = analyticsSessionProperties(model: model)
        properties["model_id"] = .string(modelId)
        if let previousModelId {
            properties["previous_model_id"] = .string(previousModelId)
        }
        AnalyticsClient.shared.capture(.modelSelected, properties: properties)
    }

    private func captureHarnessSelected(harnessId: String, previousHarnessId: String?) {
        var properties = analyticsSessionProperties(model: model)
        properties["harness_id"] = .string(harnessId)
        if let previousHarnessId {
            properties["previous_harness_id"] = .string(previousHarnessId)
        }
        AnalyticsClient.shared.capture(.harnessSelected, properties: properties)
    }

    private func captureTurnEnded(_ model: SessionModel) {
        guard case let .assistant(message) = model.activeItem else { return }

        let turn = message.turn
        let currentUsage = model.usage
        let previousUsage = analyticsUsageBaseline
        analyticsUsageBaseline = currentUsage

        var properties = analyticsSessionProperties(model: model)
        if let stopReason = turn.stopReason?.rawValue {
            properties["stop_reason"] = .string(stopReason)
        }
        if let duration = turn.duration {
            properties["duration_ms"] = .integer(Int((duration * 1_000).rounded()))
        }
        properties["tool_call_count"] = .integer(turn.allToolCalls.count)

        addTokenBucket(
            key: "input_token_bucket",
            current: currentUsage?.inputTokens,
            previous: previousUsage?.inputTokens,
            to: &properties
        )
        addTokenBucket(
            key: "output_token_bucket",
            current: currentUsage?.outputTokens,
            previous: previousUsage?.outputTokens,
            to: &properties
        )
        addTokenBucket(
            key: "total_token_bucket",
            current: currentUsage?.totalTokens,
            previous: previousUsage?.totalTokens,
            to: &properties
        )

        if let cost = currentUsage?.cost {
            let previousCost = previousUsage?.cost
            let amount = previousCost?.currency == cost.currency
                ? max(0, cost.amount - (previousCost?.amount ?? 0))
                : cost.amount
            properties["cost"] = .double(amount)
            properties["cost_currency"] = .string(cost.currency)
            if let kind = cost.kind?.rawValue {
                properties["cost_kind"] = .string(kind)
            }
        }

        if model.errorMessage != nil {
            properties["error_kind"] = .string(
                model.errorRequiresHarnessAuthentication ? "authentication_required" : "runtime_error"
            )
            AnalyticsClient.shared.capture(.turnFailed, properties: properties)
        } else {
            AnalyticsClient.shared.capture(.turnCompleted, properties: properties)
        }
    }

    private func analyticsSessionProperties(model: SessionModel?) -> [String: AnalyticsPropertyValue] {
        var properties: [String: AnalyticsPropertyValue] = [:]
        if let sessionId = serverSession?.id.uuidString {
            properties["chat_id"] = .string(sessionId)
        }
        if let harnessId = connectedHarnessId ?? selectedHarnessId ?? serverSession?.harnessId,
           !harnessId.isEmpty {
            properties["harness_id"] = .string(harnessId)
        }
        let modelId = model?.configOptions.first {
            $0.category == SessionConfigOption.Category.model
        }?.currentValue ?? modelOption?.currentValue
        if let modelId, !modelId.isEmpty {
            properties["model_id"] = .string(modelId)
        }
        if let mode = model?.modeState?.currentModeId ?? modeState?.currentModeId,
           !mode.isEmpty {
            properties["mode"] = .string(mode)
        }
        return properties
    }

    private func addTokenBucket(
        key: String,
        current: UInt64?,
        previous: UInt64?,
        to properties: inout [String: AnalyticsPropertyValue]
    ) {
        guard let current else { return }
        let delta = previous.map { current >= $0 ? current - $0 : current } ?? current
        if let bucket = AnalyticsClient.tokenBucket(delta) {
            properties[key] = .string(bucket)
        }
    }

    @discardableResult
    private func prepareFromServerCapabilities(_ serverClient: any CodevisorServerClienting) async -> Bool {
        do {
            let response = try await serverClient.capabilities(cwd: project.folderURL.path)
            let capabilities = response.harnesses.filter { capability in
                capability.harness.enabled && capability.harness.isReady
            }
            applyHarnessCapabilities(capabilities)
            configCache.store(capabilities, forServer: project.serverId)
            preparationState = .ready
            return true
        } catch {
            Log.session.error("capability fetch failed: \(String(describing: error), privacy: .public)")
            if harnesses.isEmpty {
                preparationState = .failed
            }
            return false
        }
    }

    @discardableResult
    private func seedFromCachedServerCapabilities() -> Bool {
        guard serverClient != nil else { return false }
        let cached = configCache.capabilities(forServer: project.serverId).filter { capability in
            capability.harness.enabled && capability.harness.isReady
        }
        guard !cached.isEmpty else { return false }
        applyHarnessCapabilities(cached)
        return true
    }

    private func applyHarnessCapabilities(_ capabilities: [ServerHarnessCapability]) {
        let available = capabilities.map(\.harness)
        let isNewChat = resumeAgentSessionId == nil
        // Capabilities come from the project server and have already been
        // filtered to enabled, ready harnesses. Applying the app's legacy
        // global harness preference here leaks one machine's choice into all
        // the others, so the server snapshot is the sole authority.
        harnesses = available
        for capability in capabilities {
            // Inspection describes a fresh harness and carries its defaults.
            // Once a runtime is connected, its session-specific metadata is
            // authoritative: a late capability refresh must not replace a
            // resumed chat's persisted model/effort/speed with fresh-session
            // defaults (for example, changing Codex `high` back to `low`).
            let isConnectedHarness = model != nil
                && connectedHarnessId == capability.harness.id
            if !isConnectedHarness {
                configOptionsByHarness[capability.harness.id] = capability.configOptions
            }
            if let modes = capability.modes {
                modeStateByHarness[capability.harness.id] = modes
            }
            supportsGoalsByHarness[capability.harness.id] = capability.supportsGoals ?? false
        }
        if isNewChat {
            if selectedHarnessId == nil || !harnesses.contains(where: { $0.id == selectedHarnessId }) {
                selectedHarnessId = harnesses.first?.id
            }
        } else if selectedHarnessId == nil {
            selectedHarnessId = harnesses.first?.id
        }
    }
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
                    SessionMode(id: "plan", name: "Plan", canonicalId: "plan")
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
            )
        ]
    }
}
#endif
