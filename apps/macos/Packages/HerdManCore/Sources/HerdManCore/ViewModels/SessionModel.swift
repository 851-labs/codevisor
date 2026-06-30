import Foundation
import Observation
import ACPKit

/// Drives a single chat session: sends prompts, consumes the streamed
/// `SessionUpdate`s, and exposes an observable conversation for the UI.
@MainActor
@Observable
public final class SessionModel {
    public private(set) var conversation: [ConversationItem] = []
    public private(set) var isSending = false
    public var composerText: String = ""
    public private(set) var availableCommands: [AvailableCommand] = []
    public private(set) var modeState: SessionModeState?
    public private(set) var configOptions: [SessionConfigOption]
    public private(set) var errorMessage: String?
    /// Latest context-window + cost usage reported by the agent (`usage_update`).
    public private(set) var usage: SessionUsage?

    private let client: any ACPClientProtocol
    private let sessionId: String
    private let now: @Sendable () -> Date

    /// A single long-lived consumer of the session's update stream. ACP delivers
    /// `session/update` notifications continuously, and the per-session
    /// `AsyncStream` only supports one iteration — so we must NOT start a fresh
    /// `for await` per prompt (that breaks every follow-up). One consumer runs
    /// for the model's lifetime and routes updates to history vs live handling.
    private var consumerTask: Task<Void, Never>?
    private var isLoadingHistory = false

    public init(
        client: any ACPClientProtocol,
        sessionId: String,
        modeState: SessionModeState? = nil,
        configOptions: [SessionConfigOption] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.sessionId = sessionId
        self.modeState = modeState
        self.configOptions = configOptions
        self.now = now
    }

    /// Starts the single long-lived update consumer (idempotent). The update
    /// stream is obtained here (before the loop) so the consumer begins applying
    /// immediately — `drain()` must not declare the buffer empty before the
    /// consumer has started. Routes each update to history vs live handling.
    private func startConsumer() async {
        guard consumerTask == nil else { return }
        let updates = await client.updates(for: sessionId)
        consumerTask = Task { @MainActor [weak self] in
            for await update in updates {
                guard let self else { break }
                if self.isLoadingHistory {
                    self.applyHistory(update)
                } else {
                    self.apply(update)
                }
            }
        }
    }

    /// Config options of a given category (e.g. model, thought_level, mode).
    public func configOptions(category: String) -> [SessionConfigOption] {
        configOptions.filter { $0.category == category }
    }

    /// Sets a config option's value and applies the agent's updated option set.
    public func setConfigOption(configId: String, value: String) async {
        do {
            let response = try await client.setConfigOption(
                SetSessionConfigOptionRequest(sessionId: sessionId, configId: configId, value: value)
            )
            configOptions = response.configOptions
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Sends the current composer text, if any.
    public func send() async {
        await send(composerText)
    }

    /// Sends a prompt and streams the response into the conversation.
    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }

        composerText = ""
        errorMessage = nil
        conversation.append(.user(UserMessage(text: trimmed)))
        conversation.append(.assistant(AssistantMessage(
            turn: AssistantTurn(isGenerating: true, isThinking: true, startedAt: now())
        )))
        isSending = true

        // Updates are consumed by the long-lived consumer (started here if it
        // isn't already), so every prompt — first and follow-ups — streams.
        await startConsumer()

        do {
            let response = try await client.prompt(PromptRequest(sessionId: sessionId, prompt: [.text(trimmed)]))
            await drain()
            finish(stopReason: response.stopReason)
        } catch {
            await drain()
            errorMessage = String(describing: error)
            finish(stopReason: nil)
        }
        isSending = false
    }

    /// Requests cancellation of the in-flight turn.
    public func cancel() async {
        guard isSending else { return }
        try? await client.cancel(sessionId: sessionId)
    }

    /// Switches the session mode.
    public func setMode(_ modeId: String) async {
        try? await client.setMode(SetSessionModeRequest(sessionId: sessionId, modeId: modeId))
        if var state = modeState {
            state.currentModeId = modeId
            modeState = state
        }
    }

    // MARK: - History (session/load)

    private var loadingUserText: String?

    /// Consumes a resumed session's replayed history (delivered as buffered
    /// `session/update`s after `session/load`) and rebuilds the conversation,
    /// splitting it into user messages and assistant turns.
    public func loadHistory() async {
        // Reconstruct the replayed history through the shared consumer, then
        // switch it back to live application for subsequent prompts.
        isLoadingHistory = true
        await startConsumer()
        await drain()
        flushLoadingUser()
        isLoadingHistory = false
    }

    private func applyHistory(_ update: SessionUpdate) {
        appliedUpdateCount += 1
        switch update {
        case let .userMessageChunk(block):
            loadingUserText = (loadingUserText ?? "") + (block.textValue ?? "")
        case let .availableCommandsUpdate(commands):
            availableCommands = commands
        case let .currentModeUpdate(modeId):
            if var state = modeState { state.currentModeId = modeId; modeState = state }
        case let .configOptionUpdate(options):
            configOptions = options
        case let .usageUpdate(usage):
            self.usage = usage
        default:
            // A non-user update finalizes the pending user message into a turn.
            flushLoadingUser()
            if case .assistant(var message) = conversation.last {
                TranscriptReducer.apply(update, to: &message.turn)
                conversation[conversation.count - 1] = .assistant(message)
            } else {
                var message = AssistantMessage(turn: AssistantTurn(isGenerating: false))
                TranscriptReducer.apply(update, to: &message.turn)
                conversation.append(.assistant(message))
            }
        }
    }

    private func flushLoadingUser() {
        guard let text = loadingUserText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            loadingUserText = nil
            return
        }
        conversation.append(.user(UserMessage(text: text)))
        conversation.append(.assistant(AssistantMessage(turn: AssistantTurn(isGenerating: false))))
        loadingUserText = nil
    }

    // MARK: - Streaming

    private var appliedUpdateCount = 0

    /// Yields until the update consumer stops applying buffered updates, so the
    /// final transcript is complete before the turn is marked finished. (ACP
    /// delivers all `session/update`s before the prompt response, so once the
    /// applied count stabilizes the buffer is drained.)
    private func drain() async {
        var stableRounds = 0
        var lastCount = appliedUpdateCount
        var iterations = 0
        while stableRounds < 2 && iterations < 500 {
            await Task.yield()
            iterations += 1
            if appliedUpdateCount == lastCount {
                stableRounds += 1
            } else {
                stableRounds = 0
                lastCount = appliedUpdateCount
            }
        }
    }

    private func apply(_ update: SessionUpdate) {
        appliedUpdateCount += 1
        switch update {
        case let .availableCommandsUpdate(commands):
            availableCommands = commands
        case let .currentModeUpdate(modeId):
            if var state = modeState {
                state.currentModeId = modeId
                modeState = state
            }
        case let .configOptionUpdate(options):
            configOptions = options
        case let .usageUpdate(usage):
            self.usage = usage
        default:
            guard case .assistant(var message) = conversation.last else { return }
            TranscriptReducer.apply(update, to: &message.turn)
            conversation[conversation.count - 1] = .assistant(message)
        }
    }

    /// Seeds conversation state for previews. Not for production use.
    public func applyPreviewState(conversation: [ConversationItem], isSending: Bool, usage: SessionUsage? = nil) {
        self.conversation = conversation
        self.isSending = isSending
        self.usage = usage
    }

    private func finish(stopReason: StopReason?) {
        guard case .assistant(var message) = conversation.last else { return }
        message.turn.isGenerating = false
        message.turn.isThinking = false
        message.turn.stopReason = stopReason
        message.turn.endedAt = now()
        conversation[conversation.count - 1] = .assistant(message)
    }
}
