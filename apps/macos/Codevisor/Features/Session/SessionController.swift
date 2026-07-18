import Foundation
import Observation
import CodevisorCore
import ACPKit
import UniformTypeIdentifiers
import os

/// A file staged in the composer: bytes held locally for instant thumbnails,
/// uploaded eagerly so send only has to collect the server refs.
struct ComposerAttachment: Identifiable, Equatable {
    enum State: Equatable {
        case uploading
        case uploaded(ServerAttachmentRef)
        case failed(String)
    }

    let id: UUID
    var name: String
    var mimeType: String
    var kind: Attachment.Kind
    var localData: Data
    var state: State

    var isImage: Bool { kind == .image }

    var isPDF: Bool {
        mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
    }

    var isVideo: Bool { attachmentIsVideo(name: name, mimeType: mimeType) }

    /// Images, PDFs, and videos render as visual previews; everything else is a chip.
    var hasVisualPreview: Bool { isImage || isPDF || isVideo }
}

/// One measured settled-row height. The revision prevents a stale height from
/// being reused if the row's content changed while it was offscreen.
struct SessionMeasuredRow: Equatable {
    var height: CGFloat
    var revision: Int
}

/// Text layout depends on the actual row width and the app's typography. Keep
/// those dimensions in the cache key so a sidebar resize cannot poison a later
/// restoration at another width.
struct SessionMeasurementCacheKey: Hashable {
    /// Effective row width in half-point buckets. Sub-pixel window jitter does
    /// not create a new cache, while a real reflow does.
    var rowWidthHalfPoints: Int
    var layoutFingerprint: Int
}

/// The mounted virtual window saved alongside a transcript coordinate. This
/// mirrors ChatGPT's `renderedWindow`: restoration mounts the same neighborhood
/// before any estimates are allowed to choose a different part of the thread.
struct SessionRenderedTranscriptWindow: Equatable {
    var anchorKey: String
    var count: Int
}

/// Virtualizer-owned restore data. The height map is the exact geometry that
/// produced the saved coordinate; the regular LRU remains the longer-lived
/// cache used across width changes.
struct SessionVirtualTranscriptRestoreState: Equatable {
    var measurementCacheKey: SessionMeasurementCacheKey?
    var rowHeightsByKey: [String: CGFloat]
    var renderedWindow: SessionRenderedTranscriptWindow?
}

/// User intent for how the transcript should react to future content. This is
/// deliberately independent from viewport geometry: restoring or remeasuring
/// rows can move the viewport a few points without meaning that the user chose
/// to stop following the latest turn.
enum SessionTranscriptFollowMode: Equatable {
    case staticPosition
    case followingLatest

    var followsLatest: Bool { self == .followingLatest }
}

/// Where the transcript was scrolled when the user last looked at a session,
/// kept on the cached controller so navigating away and back reopens the
/// transcript at the same place instead of pinned to the bottom.
struct SessionScrollState {
    /// The single persisted viewport coordinate, matching ChatGPT's thread
    /// scroll model. Zero means the latest content is visible.
    var distanceFromBottom: CGFloat
    /// A tiny, bounded LRU of exact settled-row measurements. Dictionary
    /// snapshots are copy-on-write, so publishing scroll state remains O(1).
    var measurementCaches: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]]
    var measurementCacheLRU: [SessionMeasurementCacheKey]
    /// Exact virtual window and row geometry from the last mounted view.
    var virtualTranscript: SessionVirtualTranscriptRestoreState?
    /// Follow intent is persisted separately from the viewport coordinate.
    var followMode: SessionTranscriptFollowMode
    var isAtBottom: Bool { distanceFromBottom <= 2 }
}

/// The facade for a session screen. Holds the composer text and harness
/// selection, connects the session through the Codevisor server on first send,
/// then forwards to the live `SessionModel`.
@MainActor
@Observable
final class SessionController {
    enum Status: Equatable {
        case idle
        case connecting(String)
        case failed(String)
    }

    /// Loading, an authoritative empty result, and a request failure are
    /// distinct UI states. An empty harness array alone cannot represent all
    /// three without briefly claiming that no agent is installed.
    enum PreparationState: Equatable {
        case loading
        case ready
        case failed
    }

    var composerText: String = "" { didSet { draftDidChange() } }
    private(set) var composerAttachments: [ComposerAttachment] = [] { didSet { draftDidChange() } }
    /// Attachments shown with the optimistic first message while connecting.
    private(set) var pendingUserAttachments: [Attachment] = []
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var harnesses: [ServerHarness] = []
    private(set) var preparationState: PreparationState = .loading
    var selectedHarnessId: String? { didSet { draftDidChange() } }
    private(set) var model: SessionModel?
    private(set) var status: Status = .idle
    /// The first prompt, held while the session record/agent are being created
    /// so the UI can show it optimistically the instant the user sends.
    private(set) var pendingUserText: String?
    /// The transcript scroll position, updated on every scroll tick and read
    /// back when the session screen remounts. Observation-ignored so the
    /// high-frequency writes don't invalidate views observing the controller.
    @ObservationIgnored var scrollState: SessionScrollState? {
        didSet { onScrollStateChange?(scrollState) }
    }
    /// SessionStore mirrors viewport state independently from the heavier
    /// controller LRU, so browsing many chats can evict transcript models
    /// without forgetting where the user was reading.
    @ObservationIgnored var onScrollStateChange: ((SessionScrollState?) -> Void)?
    /// Whether the pinned todo checklist is expanded. SessionStore mirrors
    /// this independently so navigation and controller eviction preserve the
    /// last state the user chose for each chat.
    var isTodosExpanded = true {
        didSet { onTodosExpandedChange?(isTodosExpanded) }
    }
    @ObservationIgnored var onTodosExpandedChange: ((Bool) -> Void)?
    /// Tracks the completion edge separately from disclosure state so a user
    /// can reopen a finished checklist without it immediately closing again.
    @ObservationIgnored private var todosWereCompleted = false
    @ObservationIgnored var onTodosCompletionChange: ((Bool) -> Void)?
    /// User-toggled expand/collapse state for transcript rows, hoisted out of
    /// per-row `@State` so it survives lazy unmounts.
    @ObservationIgnored let disclosure = TranscriptDisclosureStore()
    /// Bumped on every user send; the session screen observes it to re-pin
    /// the transcript to the bottom (sending means "show me the newest").
    private(set) var userSendSignal = 0
    /// A fresh, monotonic request for the transcript to animate the next user
    /// row out of the bottom chrome. Direct sends trigger it immediately;
    /// queued sends trigger it only when the server promotes them into the
    /// transcript, not when they first enter the queue.
    private(set) var userSendAnimationSignal = 0
    private(set) var userSendAnimationRequestedAt: TimeInterval = 0

    /// The project whose folder is used as the agent cwd. Settable so the
    /// new-chat page can change projects before the first send.
    var project: Project { didSet { draftDidChange() } }
    /// Called once, on the first send — used by the new-chat page to create and
    /// register the real session and navigate to it.
    var onFirstSend: (() -> Void)?
    /// Called when first-send setup (worktree creation or agent start) fails
    /// after `onFirstSend` already promoted the draft — the new-chat page uses
    /// it to delete the just-created session record and reopen itself with the
    /// error showing.
    var onSetupFailed: (() -> Void)?

    /// The agent session to resume (existing session); nil for a brand-new chat.
    var resumeAgentSessionId: String?
    /// The durable Codevisor session mirrored by the server. Nil for a draft until first send.
    var serverSession: ChatSession?
    /// When true, the draft runs in a new git worktree created on the first
    /// send. Until the worktree exists there is no cwd to connect with, so the
    /// eager pre-connect is skipped.
    var wantsNewWorktree = false {
        didSet {
            // A worktree kept alive from a reverted first send only makes
            // sense while worktree mode stays on; turning it off must drop the
            // override or the next send would still run in the worktree.
            if !wantsNewWorktree {
                sessionCwdOverride = nil
                worktreeName = nil
            }
            draftDidChange()
        }
    }
    /// The worktree created for this draft on first send (server-assigned slug).
    private(set) var worktreeName: String?
    /// The created worktree's path; overrides the project folder as the agent cwd.
    private(set) var sessionCwdOverride: String?
    /// Pre-chat setup steps (worktree creation, agent start) shown on the
    /// session page as "Worked for…"-style expandable sections with a live
    /// timer, streamed logs, and any failure message.
    private(set) var setupPhases: [SessionSetupPhase] = []
    /// True from the moment a send is accepted until the first-send navigation
    /// has happened — the window where the new-chat composer shows a spinner
    /// and disables input.
    private(set) var isSubmitting = false
    /// Covers the whole question-resolution transaction, including the mode
    /// switch that precedes accepting Claude's ExitPlanMode prompt. The picker
    /// responds immediately and duplicate answer/cancel tasks are ignored.
    private(set) var isResolvingQuestion = false
    /// Called once the first-send worktree has been created, so the owner can
    /// patch the already-registered session record with the worktree name/cwd.
    var onWorktreeCreated: ((ServerWorktree) -> Void)?
    /// Called with the agent session id once a brand-new session is created.
    var onAgentSessionCreated: ((String) -> Void)?
    /// Called each time a live turn ends — forwarded from the connected
    /// `SessionModel` so the session store can badge unopened chats.
    var onTurnEnded: (() -> Void)?
    /// Called for Claude runtime-state barriers so deferred attention can be
    /// released only after the overall activity epoch becomes quiescent.
    var onRuntimeStateChanged: (() -> Void)?
    /// Called when goal state changes so terminal goal outcomes can release a
    /// deferred unread/notification epoch.
    var onGoalChanged: (() -> Void)?
    /// Called when a live question pauses the agent for user input.
    var onActionRequired: (() -> Void)?
    /// The agent session id currently connected (resumed or newly created).
    private(set) var connectedAgentSessionId: String?

    private let configCache: ConfigOptionCache
    private let composerDefaults: ComposerDefaultsStore?
    private let serverClient: (any CodevisorServerClienting)?
    private var hasSentFirst = false
    private var connectedHarnessId: String?
    /// Config changes made before connecting, applied once the agent connects.
    /// Keep these scoped to their harness so switching away and back does not
    /// discard that harness's model, thinking, or speed selection.
    private var pendingConfigByHarness: [String: [String: String]] = [:] { didSet { draftDidChange() } }
    private var pendingModeId: String? { didSet { draftDidChange() } }
    @ObservationIgnored var onDraftChange: ((ComposerDraftStore.Draft) -> Void)?
    @ObservationIgnored private var isRestoringDraft = false
    /// Set only while a promoted new-chat draft is waiting for a successful
    /// agent connection. Failed setup rolls it back without counting a chat.
    private var pendingNewChatAnalytics = false
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

    init(
        project: Project,
        configCache: ConfigOptionCache,
        composerDefaults: ComposerDefaultsStore? = nil,
        serverClient: (any CodevisorServerClienting)? = nil
    ) {
        self.project = project
        self.configCache = configCache
        self.composerDefaults = composerDefaults
        self.serverClient = serverClient
        if seedFromCachedServerCapabilities() {
            preparationState = .ready
        }
    }

    func draftSnapshot() -> ComposerDraftStore.Draft {
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
            runInWorktree: wantsNewWorktree,
            configByHarness: pendingConfigByHarness,
            modeId: pendingModeId,
            isGoalComposerArmed: isGoalComposerArmed,
            isGoalEditing: isGoalEditing,
            composerTextBeforeGoalEdit: composerTextBeforeGoalEdit
        )
    }

    func restoreDraft(_ draft: ComposerDraftStore.Draft) {
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
        wantsNewWorktree = draft.runInWorktree
        pendingConfigByHarness = draft.configByHarness
        pendingModeId = draft.modeId
        isGoalComposerArmed = draft.isGoalComposerArmed
        isGoalEditing = draft.isGoalEditing
        composerTextBeforeGoalEdit = draft.composerTextBeforeGoalEdit
        isRestoringDraft = false

        // Server file ids are not assumed to survive indefinitely. Re-upload
        // the persisted local bytes and produce fresh refs for the next send.
        for attachment in composerAttachments { startUpload(attachment) }
    }

    private func draftDidChange() {
        guard !isRestoringDraft, isDraft, let onDraftChange else { return }
        onDraftChange(draftSnapshot())
    }

    var isPrepared: Bool { preparationState == .ready }

    /// The directory the agent runs in: the session's server-resolved cwd
    /// (project folder or worktree), a just-created worktree, or the project
    /// folder for plain drafts.
    var sessionCwdURL: URL {
        if let cwd = serverSession?.cwd { return URL(fileURLWithPath: cwd) }
        if let sessionCwdOverride { return URL(fileURLWithPath: sessionCwdOverride) }
        return project.folderURL
    }

    // MARK: - Derived state

    var conversation: [ConversationItem] { model?.conversation ?? [] }
    /// Split accessors for the transcript: bodies that iterate rows read the
    /// settled list; ONLY the dedicated active-row child view reads
    /// `activeItem`, so token flushes invalidate one bubble instead of the
    /// whole transcript. `hasActiveItem` is boundary-guarded for containers
    /// that need existence without per-flush invalidation.
    var settledConversation: [ConversationItem] { model?.settledConversation ?? [] }
    var activeItem: ConversationItem? { model?.activeItem }
    var activeItemRevision: UInt64 { model?.activeItemRevision ?? 0 }
    var hasActiveItem: Bool { model?.hasActiveItem ?? false }
    var hasOlderHistory: Bool { model?.hasOlderHistory ?? false }
    var isLoadingOlderHistory: Bool { model?.isLoadingOlderHistory ?? false }
    var queuedPrompts: [ServerPromptQueueItem] { model?.queuedPrompts ?? [] }
    var availableCommands: [AvailableCommand] { model?.availableCommands ?? [] }
    var isConnected: Bool { model != nil }
    /// Whether the harness can still be chosen: only a draft that hasn't sent
    /// anything yet. An empty conversation alone isn't enough — during the
    /// new-chat → session handoff the promoted controller is still connecting
    /// and its conversation is momentarily empty, which made the session
    /// composer's inline picker flash in briefly. The pending/connecting/
    /// session checks keep it hidden through that window.
    var canChooseHarness: Bool {
        conversation.isEmpty
            && pendingUserText == nil
            && !isConnecting
            && serverSession?.agentSessionId == nil
            && resumeAgentSessionId == nil
    }
    var modeState: SessionModeState? {
        if let model { return model.modeState }
        guard let selectedHarnessId, var state = modeStateByHarness[selectedHarnessId] else { return nil }
        if let pendingModeId { state.currentModeId = pendingModeId }
        return state
    }
    var errorMessage: String? { model?.errorMessage }
    var errorRequiresHarnessAuthentication: Bool {
        model?.errorRequiresHarnessAuthentication == true
    }
    /* Usage state only feeds the temporarily disabled usage gauge and popover.
    var usage: SessionUsage? { model?.usage }
    var usageLimits: ServerHarnessUsageLimits? { model?.usageLimits }
    var isLoadingUsageLimits: Bool { model?.isLoadingUsageLimits == true }
    var usageLimitsError: String? { model?.usageLimitsError }

    func loadUsageLimits(force: Bool = false) async {
        await model?.loadUsageLimits(force: force)
    }
    */

    func loadOlderHistory() async {
        await model?.loadOlderHistory()
    }

    @discardableResult
    func loadTranscriptDetails(_ itemId: String) async -> Bool {
        await model?.loadTranscriptDetails(itemId: itemId) ?? false
    }

    // MARK: - Goals

    /// The session's persistent goal, when the harness supports goal mode.
    var goal: SessionGoal? { model?.goal }

    /// Whether the selected harness supports goals at all — gates every goal
    /// affordance; harnesses without support show nothing.
    var supportsGoals: Bool {
        guard let harnessId = connectedHarnessId ?? selectedHarnessId else { return false }
        return supportsGoalsByHarness[harnessId] ?? false
    }

    /// The goal affordance shows whenever the harness supports goals; a goal
    /// set before the first send is held and applied once the agent connects.
    var canEditGoal: Bool { supportsGoals }

    /// Goal-input mode: when armed, submitting the composer sets the text as
    /// the session goal instead of sending a prompt.
    var isGoalComposerArmed = false { didSet { draftDidChange() } }

    /// The pencil-edit flow: the composer strips down to a dedicated
    /// "Edit goal" editor and the banner hides. Plain ⌖-armed goal setting
    /// keeps the normal composer look.
    var isGoalEditing = false { didSet { draftDidChange() } }

    /// Editing an existing goal temporarily replaces the visible chat draft.
    /// Keep the draft here so cancelling or finishing the edit cannot destroy
    /// text the user had already composed.
    private var composerTextBeforeGoalEdit: String? { didSet { draftDidChange() } }

    /// A goal captured before the session connected, applied on connect.
    private var pendingGoal: String?

    func toggleGoalComposer() {
        if isGoalComposerArmed {
            exitGoalComposer()
        } else {
            isGoalComposerArmed = true
        }
    }

    /// Leaves goal mode without mutating an ordinary composer draft. Editing
    /// an existing goal restores the chat draft that the edit displaced.
    func exitGoalComposer() {
        isGoalComposerArmed = false
        isGoalEditing = false
        if let composerTextBeforeGoalEdit {
            composerText = composerTextBeforeGoalEdit
            self.composerTextBeforeGoalEdit = nil
        }
    }

    /// Loads the current goal into the composer in edit mode — submitting
    /// replaces the objective.
    func editGoal() {
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
    func submitGoalFromComposer() async {
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
        isSubmitting = true
        let needsWorktree = wantsNewWorktree && sessionCwdOverride == nil
        let showsSetupPhases = serverSession?.agentSessionId == nil && resumeAgentSessionId == nil
        // Whether this send is the one that promotes the new-chat draft to a
        // real session — a setup failure then reverts back to the draft.
        let promotedDraft = !hasSentFirst && onFirstSend != nil

        // Navigate first, exactly like a first prompt send.
        if !hasSentFirst {
            hasSentFirst = true
            if onFirstSend != nil {
                pendingNewChatAnalytics = true
                rememberComposerDefaults()
            }
            onFirstSend?()
            onFirstSend = nil
        }
        isSubmitting = false
        composerText = ""

        func restoreComposer() {
            composerText = objective
            pendingGoal = nil
        }

        if needsWorktree {
            if let failure = await createWorktree(showsSetupPhase: showsSetupPhases) {
                restoreComposer()
                if promotedDraft {
                    revertFirstSend(message: failure)
                } else {
                    failWorktreeSetup(with: failure, showsSetupPhase: showsSetupPhases)
                }
                return
            }
        }

        guard let harness = selectedHarness else {
            let message = "No agent is installed. Install Claude Code or Codex and try again."
            restoreComposer()
            if promotedDraft {
                revertFirstSend(message: message)
            } else {
                status = .failed(message)
            }
            return
        }
        status = .connecting("Starting \(harness.name)…")
        if showsSetupPhases { beginSetupPhase(.startingAgent(named: harness.name)) }
        do {
            // connect applies the pending goal once the agent session exists.
            let model = try await connect(harness)
            self.model = model
            setupPhases.removeAll { $0.id == SessionSetupPhase.agentPhaseId }
            status = .idle
        } catch {
            let message = serverErrorMessage(error)
            restoreComposer()
            if promotedDraft {
                revertFirstSend(message: message)
            } else {
                mutateSetupPhase(id: SessionSetupPhase.agentPhaseId) { $0.fail(message: message) }
                status = .failed(message)
            }
        }
    }

    func setGoal(objective: String? = nil, status: GoalStatus? = nil) async {
        if let model {
            await model.setGoal(objective: objective, status: status)
        } else if let objective {
            pendingGoal = objective
        }
    }

    /// The pre-connect goal shown in the banner before the session exists.
    /// Kept visible until the live goal replaces it, so the banner doesn't
    /// flicker out during the connect handshake.
    var draftGoal: SessionGoal? {
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

    func pauseGoal() async { await model?.pauseGoal() }
    func resumeGoal() async { await model?.resumeGoal() }

    func clearGoal() async {
        if model == nil {
            pendingGoal = nil
        } else {
            await model?.clearGoal()
        }
    }

    // MARK: - Todos

    /// The session's latest todo checklist, pinned above the composer.
    var todos: Plan? { model?.sessionPlan }

    /// Records the latest checklist state and reports only the unfinished →
    /// finished edge. SessionScreen owns the animation for the resulting
    /// disclosure change.
    @discardableResult
    func observeTodoCompletion(_ plan: Plan?) -> Bool {
        // A missing model means the resumed session has not loaded yet. Keep
        // the cached edge intact so remounting cannot close a checklist the
        // user deliberately reopened.
        guard model != nil else { return false }
        let isCompleted = plan?.entries.isEmpty == false
            && plan?.entries.allSatisfy { $0.status == .completed } == true
        guard isCompleted != todosWereCompleted else { return false }
        todosWereCompleted = isCompleted
        onTodosCompletionChange?(isCompleted)
        return isCompleted
    }

    /// Restores both halves of the per-session todo UI state after controller
    /// creation or LRU eviction.
    func restoreTodoDisclosure(isExpanded: Bool, wasCompleted: Bool) {
        isTodosExpanded = isExpanded
        todosWereCompleted = wasCompleted
    }

    // MARK: - Questions

    /// The question the composer renders as a picker: a real blocking agent
    /// question, or codex's client-side plan approval (below) when neither the
    /// server nor a tool drives it.
    var activeQuestion: QuestionRequest? { pendingQuestion ?? planApprovalRequest }

    /// The blocking agent question the composer renders as a picker.
    var pendingQuestion: QuestionRequest? { model?.pendingQuestion }

    func answerQuestion(answers: [String: QuestionAnswerEntry]) async {
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

    func cancelQuestion() async {
        guard !isResolvingQuestion else { return }
        isResolvingQuestion = true
        defer { isResolvingQuestion = false }
        // Dismissing codex's plan prompt just keeps planning: no message, back
        // to the composer.
        if pendingPlanApproval {
            pendingPlanApproval = false
            return
        }
        await model?.cancelQuestion()
    }

    // MARK: - Codex plan approval

    /// Codex has no ExitPlanMode tool: when a plan-mode turn ends having
    /// proposed a plan, we surface the same "implement this plan?" picker as a
    /// client-side prompt. Answering it messages the model (there is no held
    /// tool to resolve) — mirroring codex CLI's approve = leave-plan-mode +
    /// "Implement the plan." user turn.
    private(set) var pendingPlanApproval = false

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
    var configOptions: [SessionConfigOption] {
        if let model { return model.configOptions }
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

    /// The model choice shown in the combined model dropdown.
    var modelOption: SessionConfigOption? {
        configOptions.first { $0.category == SessionConfigOption.Category.model && !$0.options.isEmpty }
    }

    /// The thinking/reasoning level shown in the combined model dropdown.
    var thoughtLevelOption: SessionConfigOption? {
        configOptions.first { $0.category == SessionConfigOption.Category.thoughtLevel && !$0.options.isEmpty }
    }

    /// The speed (standard/fast) shown in the combined model dropdown; only
    /// present when the agent/model pair supports a fast tier.
    var speedOption: SessionConfigOption? {
        configOptions.first { $0.category == SessionConfigOption.Category.speed && !$0.options.isEmpty }
    }

    var hasModelMenu: Bool {
        modelOption != nil || thoughtLevelOption != nil || speedOption != nil
    }

    /// The config options still shown as individual picker chips (model
    /// config, unknown categories), in a sensible order. Mode options are
    /// excluded entirely: the composer's plan toggle is the only mode control
    /// (everything else runs in the harness's full-access/build default).
    var pickerOptions: [SessionConfigOption] {
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

    func setConfigOption(_ configId: String, _ value: String) async {
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
        }
    }

    // MARK: - Remembered composer defaults

    /// True until the first send creates the real session — the window where
    /// remembered defaults apply and harness switches re-seed them.
    private var isDraft: Bool { serverSession == nil && !hasSentFirst }

    /// Seeds a new-chat draft with the choices the last session was created
    /// with: the harness and that harness's config selections (model,
    /// reasoning, …). Called once by `SessionStore` when a draft is made.
    func applyComposerDefaults() {
        guard let composerDefaults, isDraft else { return }
        if let harnessId = composerDefaults.lastHarnessId(forServer: project.serverId), !harnessId.isEmpty,
           harnesses.isEmpty || harnesses.contains(where: { $0.id == harnessId }) {
            selectedHarnessId = harnessId
        }
        wantsNewWorktree = composerDefaults.runInWorktree(forServer: project.serverId)
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
            onServer: project.serverId
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

    /// Records the choices this draft is being created with so the next new
    /// chat starts from the same setup. Mode is deliberately excluded —
    /// approval modes shouldn't silently stick across sessions.
    private func rememberComposerDefaults() {
        guard let composerDefaults else { return }
        let rememberedCategories: Set<String> = [
            SessionConfigOption.Category.model,
            SessionConfigOption.Category.thoughtLevel,
            SessionConfigOption.Category.speed,
            SessionConfigOption.Category.modelConfig
        ]
        let values = configOptions
            .filter { rememberedCategories.contains($0.category ?? "") }
            .map { ($0.id, $0.currentValue) }
        composerDefaults.rememberSessionCreation(
            serverId: project.serverId,
            harnessId: selectedHarnessId,
            configValues: Dictionary(values) { _, last in last },
            runInWorktree: wantsNewWorktree
        )
    }

    var selectedHarness: ServerHarness? {
        harnesses.first { $0.id == selectedHarnessId }
    }

    var isConnecting: Bool {
        if case .connecting = status { return true }
        return false
    }

    /// Whether the session is actively generating a response.
    var isSending: Bool { model?.isSending ?? false }
    var isCancelling: Bool { model?.isCancelling ?? false }

    var isBusy: Bool {
        isConnecting || isSending
    }

    /// Background tasks the agent is running (backgrounded shells, subagents).
    var backgroundTasks: [BackgroundTaskInfo] { model?.backgroundTasks ?? [] }

    /// Whether any background-task snapshot has arrived (see SessionModel).
    var hasBackgroundTaskSnapshot: Bool { model?.hasBackgroundTaskSnapshot ?? false }

    /// Background tasks with no attachable terminal — the ones the waiting
    /// indicator describes. Terminal-backed tasks surface as terminal tabs.
    var waitingBackgroundTasks: [BackgroundTaskInfo] { model?.waitingBackgroundTasks ?? [] }

    /// True when the turn ended but the agent still owns background work — the
    /// chat isn't stuck; the agent will come back on its own.
    var isWaitingOnBackgroundTasks: Bool { model?.isWaitingOnBackgroundTasks ?? false }
    var isRuntimeIdle: Bool { model?.isRuntimeIdle ?? true }
    var lastTurnInitiator: SessionTurnInitiator { model?.lastTurnInitiator ?? .user }
    var lastTurnEndedWithError: Bool { model?.lastTurnEndedWithError ?? false }

    var waitingBackgroundTaskDescription: String? {
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
    var runningSubagentToolCallIds: Set<String> { model?.runningSubagentToolCallIds ?? [] }

    var canSend: Bool {
        (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !composerAttachments.isEmpty)
            && !isConnecting
            && (isConnected || selectedHarness != nil)
    }

    // MARK: - Attachments

    /// Largest upload the server accepts; checked client-side for a friendly
    /// inline failure instead of a 413 round-trip.
    static let maxAttachmentBytes = 25 * 1024 * 1024
    static let maxAttachments = 10

    func attachFileURLs(_ urls: [URL]) {
        for url in urls {
            attachFileURL(url)
        }
    }

    /// Stages one dropped/picked file. The bytes are read off the main
    /// thread — a multi-gigabyte drop or a file on a slow network volume
    /// must not freeze the run loop — and the size is checked *before*
    /// reading so an oversized file fails fast without ever loading.
    private func attachFileURL(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        let kind: Attachment.Kind = (type?.conforms(to: .image) ?? false) || mimeType.hasPrefix("image/")
            ? .image
            : .file
        let maxBytes = Self.maxAttachmentBytes
        Task { [weak self] in
            // (data, oversized, readError): (nil, false, error) = unreadable →
            // staged as a failed chip, same surface as oversized files.
            let result: (data: Data?, oversized: Bool, readError: String?) = await Task.detached(priority: .userInitiated) {
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                   size > maxBytes {
                    return (nil, true, nil)
                }
                do {
                    let data = try Data(contentsOf: url)
                    return data.count > maxBytes ? (nil, true, nil) : (data, false, nil)
                } catch {
                    return (nil, false, String(describing: error))
                }
            }.value
            guard let self else { return }
            if result.oversized {
                self.stageAttachment(
                    name: url.lastPathComponent, mimeType: mimeType, kind: kind,
                    data: Data(), oversized: true
                )
            } else if let data = result.data {
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

    func attachImageData(_ data: Data, suggestedName: String? = nil) {
        let name = suggestedName ?? "Pasted image \(Self.pastedImageFormatter.string(from: Date())).png"
        stageAttachment(name: name, mimeType: "image/png", kind: .image, data: data)
    }

    func removeAttachment(id: UUID) {
        uploadTasks[id]?.cancel()
        uploadTasks[id] = nil
        composerAttachments.removeAll { $0.id == id }
    }

    func retryAttachment(id: UUID) {
        guard let index = composerAttachments.firstIndex(where: { $0.id == id }),
              case .failed = composerAttachments[index].state else { return }
        composerAttachments[index].state = .uploading
        startUpload(composerAttachments[index])
    }

    /// Fetches stored attachment bytes through this session's server client —
    /// History thumbnails and Quick Look load through here so auth carries
    /// over for remote servers.
    func fileData(id: String) async throws -> Data {
        guard let serverClient else { throw SessionControllerError.serverUnavailable }
        return try await serverClient.fileData(id: id)
    }

    private func stageAttachment(
        name: String, mimeType: String, kind: Attachment.Kind, data: Data, oversized: Bool = false,
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
        if oversized || data.count > Self.maxAttachmentBytes {
            attachment.state = .failed("Larger than 25 MB")
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
    func prepare() async {
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

    /// Reloads the authoritative harness catalog after authentication or
    /// enablement changes. Unlike `prepare()`, this deliberately bypasses the
    /// stale cache because the caller is responding to an explicit mutation.
    func refreshHarnessCapabilities() async {
        guard let serverClient else {
            preparationState = .failed
            return
        }
        _ = await prepareFromServerCapabilities(serverClient)
    }

    /// Eagerly connects the selected harness (without sending) so model and
    /// reasoning config options are available in the composer before the first
    /// message. Safe to call repeatedly.
    func connectIfNeeded() async {
        guard model == nil, !isConnecting, let harness = selectedHarness else { return }
        // A worktree draft has no cwd until the worktree is created on first
        // send; connecting now would pin the agent to the project folder.
        guard !wantsNewWorktree || sessionCwdOverride != nil else { return }
        guard serverSession != nil else { return }
        status = .connecting("Starting \(harness.name)…")
        do {
            model = try await connect(harness)
            status = .idle
        } catch {
            status = .failed(serverErrorMessage(error))
        }
    }

    /// Selects a different harness (user action) and reconnects.
    func selectHarness(_ id: String) async {
        guard id != selectedHarnessId else { return }
        let previousHarnessId = selectedHarnessId
        selectedHarnessId = id
        captureHarnessSelected(harnessId: id, previousHarnessId: previousHarnessId)
        if isDraft {
            // Start the new harness from its own remembered selections rather
            // than pending edits made under the previous harness.
            seedRememberedConfig()
        }
        if var serverSession {
            serverSession.harnessId = id
            self.serverSession = serverSession
        }
        await reconnect()
    }

    /// Changes the project (user action) and reconnects.
    func selectProject(_ project: Project) async {
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
    func reconnect() async {
        model = nil
        status = .idle
        await connectIfNeeded()
    }

    /// Sends the composer text, connecting the harness first if needed. A
    /// first send navigates to the session page immediately; the pre-chat
    /// steps that follow (worktree creation, agent start) stream their
    /// progress there as `setupPhases`.
    func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !composerAttachments.isEmpty, !isConnecting, !isSubmitting else { return }
        let shouldAnimateTranscriptSend = !isSending
        // Ask at the first moment notifications become useful instead of at
        // launch: the user just started work that may finish while they are in
        // another app. The task is intentionally nonblocking for the send.
        Task { await ChatNotificationManager.shared.prepareAuthorizationIfNeeded() }
        // Sending expresses "take me to the newest content": the transcript
        // re-pins to the bottom on every send, even if the user had scrolled
        // up to read history.
        userSendSignal &+= 1
        isSubmitting = true

        // Settle eager uploads first; a failed attachment blocks the send with
        // an inline status instead of silently dropping the file.
        guard let attachments = await collectAttachmentsForSend() else {
            isSubmitting = false
            return
        }

        // Request the motion only once all attachments have settled and the
        // send is certain to proceed. The row is inserted immediately after
        // this point, which lets the transcript reject stale requests after a
        // remount without losing slow attachment sends.
        if shouldAnimateTranscriptSend {
            requestUserSendAnimation()
        }

        let needsWorktree = wantsNewWorktree && sessionCwdOverride == nil
        // A brand-new chat renders its pre-chat steps as setup sections; a
        // resumed session's transcript shouldn't grow one retroactively.
        let showsSetupPhases = serverSession?.agentSessionId == nil && resumeAgentSessionId == nil
        // Whether this send is the one that promotes the new-chat draft to a
        // real session — a setup failure then reverts back to the draft.
        let promotedDraft = !hasSentFirst && onFirstSend != nil

        // Navigate first: the session page opens the instant the user sends
        // and shows the optimistic message plus live setup progress.
        if !hasSentFirst {
            hasSentFirst = true
            // Only a new-chat draft (which has an onFirstSend) sets the
            // defaults; a resumed session's first message shouldn't.
            if onFirstSend != nil {
                pendingNewChatAnalytics = true
                rememberComposerDefaults()
            }
            onFirstSend?()
            onFirstSend = nil
        }
        isSubmitting = false

        // Clear before any await: the session page reuses this controller, and
        // the sent text lingering in the composer next to the optimistic user
        // message reads as a duplicate. Failure paths restore it.
        composerText = ""
        let staged = composerAttachments
        composerAttachments = []

        // Show the first message optimistically while pre-chat setup runs.
        if model == nil || needsWorktree {
            pendingUserText = text
            pendingUserAttachments = attachments
        }

        func restoreComposer() {
            composerText = text
            composerAttachments = staged
            pendingUserText = nil
            pendingUserAttachments = []
        }

        // Materialize the worktree before the agent exists, so it is born with
        // the worktree cwd. Progress (including checkout-hook output) streams
        // into the "Setting up worktree…" section.
        if needsWorktree {
            if let failure = await createWorktree(showsSetupPhase: showsSetupPhases) {
                restoreComposer()
                if promotedDraft {
                    revertFirstSend(message: failure)
                } else {
                    failWorktreeSetup(with: failure, showsSetupPhase: showsSetupPhases)
                }
                return
            }
        }

        if let model {
            pendingUserText = nil
            pendingUserAttachments = []
            await model.send(text, attachments: attachments)
            return
        }

        guard let harness = selectedHarness else {
            let message = "No agent is installed. Install Claude Code or Codex and try again."
            restoreComposer()
            if promotedDraft {
                revertFirstSend(message: message)
            } else {
                status = .failed(message)
            }
            return
        }
        status = .connecting("Starting \(harness.name)…")
        if showsSetupPhases { beginSetupPhase(.startingAgent(named: harness.name)) }
        do {
            let model = try await connect(harness)
            self.model = model
            // Agent start is quick, so the row is ephemeral: it narrates while
            // running and simply disappears on success (failures stay).
            setupPhases.removeAll { $0.id == SessionSetupPhase.agentPhaseId }
            status = .idle
            // model.send appends the real user message synchronously before
            // its first suspension, so clearing here doesn't flash.
            pendingUserText = nil
            pendingUserAttachments = []
            await model.send(text, attachments: attachments)
        } catch {
            let message = serverErrorMessage(error)
            restoreComposer()
            if promotedDraft {
                revertFirstSend(message: message)
            } else {
                mutateSetupPhase(id: SessionSetupPhase.agentPhaseId) { $0.fail(message: message) }
                status = .failed(message)
            }
        }
    }

    private func requestUserSendAnimation() {
        userSendAnimationSignal &+= 1
        userSendAnimationRequestedAt = ProcessInfo.processInfo.systemUptime
    }

    /// Re-submits the user prompt that owns an exhausted retryable assistant
    /// turn. Automatic retries remain provider-owned; this is the explicit
    /// user choice offered after they give up.
    func retryTurn(_ assistantID: UUID) async {
        guard let model, !model.isSending, !isConnecting, !isSubmitting else { return }
        guard let assistantIndex = model.conversation.firstIndex(where: { item in
            if case let .assistant(message) = item { return message.id == assistantID }
            return false
        }) else { return }
        guard let prompt = model.conversation[..<assistantIndex].reversed().compactMap({ item in
            if case let .user(message) = item { return message }
            return nil
        }).first else { return }
        userSendSignal &+= 1
        await model.send(prompt.text, attachments: prompt.attachments)
    }

    /// Rolls a failed first send back to the draft state. The setup sections
    /// belong to the session page being torn down; the error travels back to
    /// the new-chat page as a `.failed` status, and `onSetupFailed` (wired by
    /// the new-chat page) deletes the just-created session record and
    /// navigates back. A worktree that was already created is kept on the
    /// controller so a retry reuses it instead of materializing another one.
    private func revertFirstSend(message: String) {
        setupPhases.removeAll()
        hasSentFirst = false
        pendingNewChatAnalytics = false
        status = .failed(message)
        onSetupFailed?()
        onSetupFailed = nil
    }

    /// Asks the server to create a git worktree for this draft. The server
    /// owns the fixed location (~/codevisor/{projectId}/{name}) and picks a
    /// random memorable name ("ferocious-walrus"); the app never computes
    /// either. The worktree id is generated client-side so the server's
    /// `worktree.setup` events (git output, checkout hooks, failures) can be
    /// followed live into the setup section while the request is in flight.
    /// Returns the failure message on error (nil on success); the caller
    /// routes it into the setup section, the status, or a first-send revert.
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
            return worktreeFailureMessage(from: message)
        } catch {
            return serverErrorMessage(error)
        }
    }

    /// Surfaces a worktree failure: in the setup section when the session page
    /// shows one (the error and captured logs stay expandable there), or as a
    /// plain failed status otherwise.
    private func failWorktreeSetup(with message: String, showsSetupPhase: Bool) {
        if showsSetupPhase {
            mutateSetupPhase(id: SessionSetupPhase.worktreePhaseId) { $0.fail(message: message) }
            status = .idle
        } else {
            status = .failed(message)
        }
    }

    private func beginSetupPhase(_ phase: SessionSetupPhase) {
        setupPhases.removeAll { $0.id == phase.id }
        setupPhases.append(phase)
    }

    private func mutateSetupPhase(id: String, _ transform: (inout SessionSetupPhase) -> Void) {
        guard let index = setupPhases.firstIndex(where: { $0.id == id }) else { return }
        transform(&setupPhases[index])
    }

    private func worktreeFailureMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode([String: String].self, from: data),
              let error = payload["error"] else {
            return body.isEmpty ? "Could not create the worktree." : body
        }
        return error
    }

    func stop() async {
        await model?.cancel()
    }

    func updateQueuedPrompt(id: String, text: String) async {
        await model?.updateQueuedPrompt(id: id, text: text)
    }

    func deleteQueuedPrompt(id: String) async {
        await model?.deleteQueuedPrompt(id: id)
    }

    func setMode(_ modeId: String) async {
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
    var hasPlanMode: Bool { planControl != nil }

    var isPlanModeOn: Bool {
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

    var isPlanModeUpdatePending: Bool { pendingPlanModeOn != nil }

    func togglePlanMode() async {
        // The button is disabled while pending too, but keep the guard here so
        // multiple click tasks queued before SwiftUI redraws cannot submit the
        // same transition more than once.
        guard pendingPlanModeOn == nil, let planControl else { return }
        let targetIsOn = !isPlanModeOn
        pendingPlanModeOn = targetIsOn
        defer { pendingPlanModeOn = nil }

        switch planControl {
        case let .sessionMode(planId, buildId):
            await setMode(targetIsOn ? planId : buildId)
        case let .configOption(optionId, planValue, buildValue):
            await setConfigOption(optionId, targetIsOn ? planValue : buildValue)
        }
    }

    func retry() async {
        status = .idle
        await prepare()
    }

    // MARK: - Connection

    private func connect(_ harness: ServerHarness) async throws -> SessionModel {
        guard let serverClient, var serverSession else {
            throw SessionControllerError.serverUnavailable
        }
        return try await connectServerSession(harness, serverClient: serverClient, session: &serverSession)
    }

    private func connectServerSession(
        _ harness: ServerHarness,
        serverClient: any CodevisorServerClienting,
        session: inout ChatSession
    ) async throws -> SessionModel {
        if session.harnessId.isEmpty {
            session.harnessId = harness.id
        }
        if session.agentSessionId == nil, let resumeAgentSessionId {
            session.agentSessionId = resumeAgentSessionId
        }

        // Ensure the server knows the project before the session upsert — but
        // never overwrite an existing server record: this controller's copy is
        // a snapshot from when the draft was created, and pushing it here used
        // to revert changes made in the meantime (archiving a project while
        // its new-chat draft was connecting un-archived it again).
        let remoteProjects = try await serverClient.listProjects()
        if !remoteProjects.contains(where: { UUID(uuidString: $0.id) == project.id }) {
            _ = try await serverClient.upsertProject(project)
        }
        let remoteSession = try await serverClient.upsertSession(session)
        session = try remoteSession.chatSession()
        self.serverSession = session

        connectedHarnessId = harness.id
        if let agentSessionId = session.agentSessionId {
            connectedAgentSessionId = agentSessionId
            onAgentSessionCreated?(agentSessionId)
        }

        // Capability discovery describes a fresh harness session. A resumed
        // thread can have a different current model and model-specific effort
        // list, so let the loaded runtime replace the generic/cache snapshot.
        if session.agentSessionId?.isEmpty == false,
           let metadata = try await serverClient.connectSession(id: session.id) {
            if !metadata.configOptions.isEmpty {
                configOptionsByHarness[harness.id] = metadata.configOptions
            }
            if let modes = metadata.modes {
                modeStateByHarness[harness.id] = modes
            }
            if let supportsGoals = metadata.supportsGoals {
                supportsGoalsByHarness[harness.id] = supportsGoals
            }
        }

        let transport = ServerSessionTransport(client: serverClient, sessionId: session.id)
        let model = SessionModel(
            serverTransport: transport,
            sessionId: session.id.uuidString,
            modeState: modeStateByHarness[harness.id],
            configOptions: configOptionsByHarness[harness.id]
                ?? configCache.options(forHarness: harness.id, onServer: project.serverId)
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
            self?.captureMessageSent(model: model, attachmentCount: attachmentCount, isQueued: isQueued)
        }
        model.onQueuedPromptPromoted = { [weak self] in
            self?.requestUserSendAnimation()
        }
        model.onActionRequired = { [weak self] in
            self?.onActionRequired?()
        }
        // Negotiate the canonical transcript + session-scoped event stream
        // for every server-backed model, including a brand-new empty chat.
        // Skipping this on first send leaves `usesPaginatedHistory` false, so
        // SessionModel falls back to the global compatibility stream. Current
        // servers deliberately exclude session runtime traffic from that
        // stream, which means the answer is persisted but its chunks and
        // terminal event never reach the live UI. Older servers still fall
        // back inside loadHistory() when the transcript endpoint returns 404.
        await model.loadHistory()
        analyticsUsageBaseline = model.usage

        if let pendingModeId {
            await model.setMode(pendingModeId)
        }
        pendingModeId = nil

        // Model changes can replace the model-specific thinking and speed
        // options. Apply dependent selections afterward so a remembered fast
        // tier is available by the time it is restored.
        let pendingConfig = pendingConfigByHarness[harness.id] ?? [:]
        let optionCategories = Dictionary(
            uniqueKeysWithValues: model.configOptions.map { ($0.id, $0.category ?? "") }
        )
        let categoryOrder = [
            SessionConfigOption.Category.model: 0,
            SessionConfigOption.Category.thoughtLevel: 1,
            SessionConfigOption.Category.speed: 2
        ]
        let orderedPendingConfig = pendingConfig.sorted { left, right in
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
        pendingConfigByHarness[harness.id] = nil

        captureChatCreatedIfNeeded(model: model, harnessId: harness.id)
        await applyPendingGoal(to: model)

        configCache.store(model.configOptions, forHarness: harness.id, onServer: project.serverId)
        configOptionsByHarness[harness.id] = model.configOptions
        return model
    }

    // MARK: - Analytics

    private func captureChatCreatedIfNeeded(model: SessionModel, harnessId: String) {
        guard pendingNewChatAnalytics else { return }
        pendingNewChatAnalytics = false
        var properties = analyticsSessionProperties(model: model)
        properties["harness_id"] = .string(harnessId)
        properties["uses_worktree"] = .boolean(wantsNewWorktree || serverSession?.worktreeName != nil)
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
            configOptionsByHarness[capability.harness.id] = capability.configOptions
            if let model,
               (connectedHarnessId ?? selectedHarnessId) == capability.harness.id {
                model.replaceConfigOptions(capability.configOptions)
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

enum SessionControllerError: Error {
    /// Sessions run through the Codevisor server; without it there is nothing to
    /// connect to.
    case serverUnavailable
}

#if DEBUG
extension SessionController {
    /// A controller pre-populated for previews.
    static func preview(
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

    nonisolated static var previewHarnesses: [ServerHarness] {
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
