import Foundation
import Observation
import HerdManCore
import ACPKit
import UniformTypeIdentifiers

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

    /// Images and PDFs render as visual previews; everything else is a chip.
    var hasVisualPreview: Bool { isImage || isPDF }
}

/// Where the transcript was scrolled when the user last looked at a session,
/// kept on the cached controller so navigating away and back reopens the
/// transcript at the same place instead of pinned to the bottom.
struct SessionScrollState {
    /// The scroll view's content offset (`contentOffset.y`) at capture time.
    /// Only a first approximation for restoring: the lazy transcript's
    /// estimated row heights make raw offsets drift between mounts.
    var offsetY: CGFloat
    /// The topmost visible conversation item at capture time — the precise
    /// restore anchor, immune to lazy height re-estimation.
    var anchorItemID: UUID?
    /// How far the anchor item's top sat above the visible top, in points
    /// (negative when its top was below the visible top).
    var anchorDelta: CGFloat = 0
    /// True when the user was reading the latest messages; reopening then
    /// keeps the pin-to-bottom behavior (and follows new streamed output).
    var isAtBottom: Bool
}

/// The facade for a session screen. Holds the composer text and harness
/// selection, connects the session through the HerdMan server on first send,
/// then forwards to the live `SessionModel`.
@MainActor
@Observable
final class SessionController {
    enum Status: Equatable {
        case idle
        case connecting(String)
        case failed(String)
    }

    var composerText: String = ""
    private(set) var composerAttachments: [ComposerAttachment] = []
    /// Attachments shown with the optimistic first message while connecting.
    private(set) var pendingUserAttachments: [Attachment] = []
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var harnesses: [ServerHarness] = []
    var selectedHarnessId: String?
    private(set) var model: SessionModel?
    private(set) var status: Status = .idle
    /// The first prompt, held while the session record/agent are being created
    /// so the UI can show it optimistically the instant the user sends.
    private(set) var pendingUserText: String?
    /// The transcript scroll position, updated on every scroll tick and read
    /// back when the session screen remounts. Observation-ignored so the
    /// high-frequency writes don't invalidate views observing the controller.
    @ObservationIgnored var scrollState: SessionScrollState?

    /// The project whose folder is used as the agent cwd. Settable so the
    /// new-chat page can change projects before the first send.
    var project: Project
    /// Called once, on the first send — used by the new-chat page to create and
    /// register the real session and navigate to it.
    var onFirstSend: (() -> Void)?

    /// The agent session to resume (existing session); nil for a brand-new chat.
    var resumeAgentSessionId: String?
    /// The durable HerdMan session mirrored by the server. Nil for a draft until first send.
    var serverSession: ChatSession?
    /// When true, the draft runs in a new git worktree created on the first
    /// send. Until the worktree exists there is no cwd to connect with, so the
    /// eager pre-connect is skipped.
    var wantsNewWorktree = false
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
    /// Called once the first-send worktree has been created, so the owner can
    /// patch the already-registered session record with the worktree name/cwd.
    var onWorktreeCreated: ((ServerWorktree) -> Void)?
    /// Called with the agent session id once a brand-new session is created.
    var onAgentSessionCreated: ((String) -> Void)?
    /// The agent session id currently connected (resumed or newly created).
    private(set) var connectedAgentSessionId: String?

    private let configCache: ConfigOptionCache
    private let composerDefaults: ComposerDefaultsStore?
    private let settings: AppSettingsModel?
    private let serverClient: (any HerdManServerClienting)?
    private var hasSentFirst = false
    private var connectedHarnessId: String?
    /// Config changes made before connecting, applied once the agent connects.
    private var pendingConfig: [String: String] = [:]
    private var pendingModeId: String?
    private var modeStateByHarness: [String: SessionModeState] = [:]
    private var configOptionsByHarness: [String: [SessionConfigOption]] = [:]

    init(
        project: Project,
        configCache: ConfigOptionCache,
        composerDefaults: ComposerDefaultsStore? = nil,
        settings: AppSettingsModel? = nil,
        serverClient: (any HerdManServerClienting)? = nil
    ) {
        self.project = project
        self.configCache = configCache
        self.composerDefaults = composerDefaults
        self.settings = settings
        self.serverClient = serverClient
        seedFromCachedServerCapabilities()
    }

    var isPrepared: Bool { !harnesses.isEmpty }

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
    var queuedPrompts: [ServerPromptQueueItem] { model?.queuedPrompts ?? [] }
    var availableCommands: [AvailableCommand] { model?.availableCommands ?? [] }
    var isConnected: Bool { model != nil }
    var modeState: SessionModeState? {
        if let model { return model.modeState }
        guard let selectedHarnessId, var state = modeStateByHarness[selectedHarnessId] else { return nil }
        if let pendingModeId { state.currentModeId = pendingModeId }
        return state
    }
    var errorMessage: String? { model?.errorMessage }
    var usage: SessionUsage? { model?.usage }

    /// Selectable config options: live when connected, otherwise the cached
    /// (stale) options for the selected harness with any pending edits applied.
    var configOptions: [SessionConfigOption] {
        if let model { return model.configOptions }
        guard let harnessId = selectedHarnessId else { return [] }
        return (configOptionsByHarness[harnessId] ?? configCache.options(forHarness: harnessId)).map { option in
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

    /// The config options still shown as individual picker chips (approval
    /// mode, model config, unknown categories), in a sensible order.
    var pickerOptions: [SessionConfigOption] {
        let order = [
            SessionConfigOption.Category.modelConfig,
            SessionConfigOption.Category.mode
        ]
        return configOptions
            .filter { !$0.options.isEmpty && !Self.modelMenuCategories.contains($0.category ?? "") }
            .sorted { left, right in
                let leftIndex = order.firstIndex(of: left.category ?? "") ?? 99
                let rightIndex = order.firstIndex(of: right.category ?? "") ?? 99
                if leftIndex == rightIndex { return left.name < right.name }
                return leftIndex < rightIndex
            }
    }

    var hasModeConfigPicker: Bool {
        pickerOptions.contains { option in
            option.category == SessionConfigOption.Category.mode || option.id == "mode"
        }
    }

    func setConfigOption(_ configId: String, _ value: String) async {
        if let model {
            await model.setConfigOption(configId: configId, value: value)
            if let harnessId = connectedHarnessId {
                configCache.store(model.configOptions, forHarness: harnessId)
                configOptionsByHarness[harnessId] = model.configOptions
            }
        } else {
            // Not connected yet: remember it and apply on connect.
            pendingConfig[configId] = value
            if let harnessId = selectedHarnessId {
                var options = configOptionsByHarness[harnessId] ?? configCache.options(forHarness: harnessId)
                if let index = options.firstIndex(where: { $0.id == configId }) {
                    options[index].currentValue = value
                    configOptionsByHarness[harnessId] = options
                }
            }
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
        if let harnessId = composerDefaults.lastHarnessId, !harnessId.isEmpty,
           harnesses.isEmpty || harnesses.contains(where: { $0.id == harnessId }) {
            selectedHarnessId = harnessId
        }
        wantsNewWorktree = composerDefaults.runInWorktree
        seedRememberedConfig()
    }

    /// Stages the remembered config selections for the selected harness as
    /// pending edits so the pickers show them and the agent applies them on
    /// connect. Values are validated against the known option lists when
    /// available; unknown lists trust the stored values and let the live
    /// agent correct them.
    private func seedRememberedConfig() {
        guard let composerDefaults, let harnessId = selectedHarnessId else { return }
        let remembered = composerDefaults.configSelections(forHarness: harnessId)
        guard !remembered.isEmpty else { return }
        var options = configOptionsByHarness[harnessId] ?? configCache.options(forHarness: harnessId)
        guard !options.isEmpty else {
            pendingConfig.merge(remembered) { _, stored in stored }
            return
        }
        for (configId, value) in remembered {
            guard let index = options.firstIndex(where: { $0.id == configId }),
                  options[index].options.contains(where: { $0.value == value }) else { continue }
            pendingConfig[configId] = value
            options[index].currentValue = value
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

    var isBusy: Bool {
        isConnecting || isSending
    }

    /// Background tasks the agent is running (backgrounded shells, subagents).
    var backgroundTasks: [BackgroundTaskInfo] { model?.backgroundTasks ?? [] }

    /// True when the turn ended but the agent still owns background work — the
    /// chat isn't stuck; the agent will come back on its own.
    var isWaitingOnBackgroundTasks: Bool { model?.isWaitingOnBackgroundTasks ?? false }

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
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
            let kind: Attachment.Kind = (type?.conforms(to: .image) ?? false) || mimeType.hasPrefix("image/")
                ? .image
                : .file
            stageAttachment(name: url.lastPathComponent, mimeType: mimeType, kind: kind, data: data)
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
    /// history thumbnails and the lightbox load through here so auth carries
    /// over for remote servers.
    func fileData(id: String) async throws -> Data {
        guard let serverClient else { throw SessionControllerError.serverUnavailable }
        return try await serverClient.fileData(id: id)
    }

    private func stageAttachment(name: String, mimeType: String, kind: Attachment.Kind, data: Data) {
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
        if data.count > Self.maxAttachmentBytes {
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
        guard let serverClient else { return }
        if seedFromCachedServerCapabilities() {
            Task { await self.prepareFromServerCapabilities(serverClient) }
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
        selectedHarnessId = id
        if isDraft {
            // Start the new harness from its own remembered selections rather
            // than pending edits made under the previous harness.
            pendingConfig.removeAll()
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
        seedFromCachedServerCapabilities()
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
        isSubmitting = true

        // Settle eager uploads first; a failed attachment blocks the send with
        // an inline status instead of silently dropping the file.
        guard let attachments = await collectAttachmentsForSend() else {
            isSubmitting = false
            return
        }

        let needsWorktree = wantsNewWorktree && sessionCwdOverride == nil
        // A brand-new chat renders its pre-chat steps as setup sections; a
        // resumed session's transcript shouldn't grow one retroactively.
        let showsSetupPhases = serverSession?.agentSessionId == nil && resumeAgentSessionId == nil

        // Navigate first: the session page opens the instant the user sends
        // and shows the optimistic message plus live setup progress.
        if !hasSentFirst {
            hasSentFirst = true
            // Only a new-chat draft (which has an onFirstSend) sets the
            // defaults; a resumed session's first message shouldn't.
            if onFirstSend != nil { rememberComposerDefaults() }
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
            guard await createWorktree(showsSetupPhase: showsSetupPhases) else {
                restoreComposer()
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
            status = .failed("No agent is installed. Install Claude Code or Codex and try again.")
            restoreComposer()
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
            mutateSetupPhase(id: SessionSetupPhase.agentPhaseId) { $0.fail(message: message) }
            status = .failed(message)
            restoreComposer()
        }
    }

    /// Asks the server to create a git worktree for this draft. The server
    /// owns the fixed location (~/herdman/{projectId}/{name}) and picks a
    /// random memorable name ("ferocious-walrus"); the app never computes
    /// either. The worktree id is generated client-side so the server's
    /// `worktree.setup` events (git output, checkout hooks, failures) can be
    /// followed live into the setup section while the request is in flight.
    /// Returns false on failure, leaving the error in the setup section (or
    /// the status for flows without one).
    private func createWorktree(showsSetupPhase: Bool) async -> Bool {
        guard let serverClient else {
            status = .failed("Worktrees need the HerdMan server. Start it and try again.")
            return false
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
            return true
        } catch let HerdManServerClientError.httpStatus(_, message) {
            failWorktreeSetup(with: worktreeFailureMessage(from: message), showsSetupPhase: showsSetupPhase)
            return false
        } catch {
            failWorktreeSetup(with: serverErrorMessage(error), showsSetupPhase: showsSetupPhase)
            return false
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
        serverClient: any HerdManServerClienting,
        session: inout ChatSession
    ) async throws -> SessionModel {
        if session.harnessId.isEmpty {
            session.harnessId = harness.id
        }
        if session.agentSessionId == nil, let resumeAgentSessionId {
            session.agentSessionId = resumeAgentSessionId
        }

        _ = try await serverClient.upsertProject(project)
        let remoteSession = try await serverClient.upsertSession(session)
        session = try remoteSession.chatSession()
        self.serverSession = session

        connectedHarnessId = harness.id
        if let agentSessionId = session.agentSessionId {
            connectedAgentSessionId = agentSessionId
            onAgentSessionCreated?(agentSessionId)
        }

        let transport = ServerSessionTransport(client: serverClient, sessionId: session.id)
        let model = SessionModel(
            serverTransport: transport,
            sessionId: session.id.uuidString,
            modeState: modeStateByHarness[harness.id],
            configOptions: configOptionsByHarness[harness.id] ?? configCache.options(forHarness: harness.id)
        )
        if resumeAgentSessionId != nil {
            await model.loadHistory()
        }

        if let pendingModeId {
            await model.setMode(pendingModeId)
        }
        pendingModeId = nil

        for (configId, value) in pendingConfig {
            await model.setConfigOption(configId: configId, value: value)
        }
        pendingConfig.removeAll()

        configCache.store(model.configOptions, forHarness: harness.id)
        configOptionsByHarness[harness.id] = model.configOptions
        return model
    }

    @discardableResult
    private func prepareFromServerCapabilities(_ serverClient: any HerdManServerClienting) async -> Bool {
        do {
            let response = try await serverClient.capabilities(cwd: project.folderURL.path)
            let capabilities = response.harnesses.filter { capability in
                capability.harness.enabled && capability.harness.isReady
            }
            applyHarnessCapabilities(capabilities)
            for capability in capabilities {
                configCache.store(capability.configOptions, forHarness: capability.harness.id)
            }
            configCache.store(capabilities, forServer: project.serverId)
            return true
        } catch {
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
        if let settings, isNewChat {
            let enabled = available.filter { settings.isHarnessEnabled($0.id) }
            harnesses = enabled.isEmpty ? available : enabled
        } else {
            harnesses = available
        }
        for capability in capabilities {
            configOptionsByHarness[capability.harness.id] = capability.configOptions
            if let modes = capability.modes {
                modeStateByHarness[capability.harness.id] = modes
            }
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
    /// Sessions run through the HerdMan server; without it there is nothing to
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
        controller.selectedHarnessId = harnesses.first?.id
        controller.model = model
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
