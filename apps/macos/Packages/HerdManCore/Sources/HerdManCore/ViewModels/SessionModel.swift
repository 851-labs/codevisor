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
    public private(set) var queuedPrompts: [ServerPromptQueueItem] = []
    public var composerText: String = ""
    public private(set) var availableCommands: [AvailableCommand] = []
    public private(set) var modeState: SessionModeState?
    public private(set) var configOptions: [SessionConfigOption]
    public private(set) var errorMessage: String?
    /// Latest context-window + cost usage reported by the agent (`usage_update`).
    public private(set) var usage: SessionUsage?

    private let transport: ServerSessionTransport
    private let sessionId: String
    private let now: @Sendable () -> Date
    private var serverEventCursor: Int?

    /// A single long-lived consumer of the session's event stream. The server
    /// delivers updates continuously — including agent-initiated turns with no
    /// prompt in flight — so one consumer runs for the model's lifetime.
    private var consumerTask: Task<Void, Never>?

    public init(
        serverTransport: ServerSessionTransport,
        sessionId: String,
        modeState: SessionModeState? = nil,
        configOptions: [SessionConfigOption] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = serverTransport
        self.sessionId = sessionId
        self.modeState = modeState
        self.configOptions = configOptions
        self.now = now
    }

    /// Starts the single long-lived event consumer (idempotent).
    private func startConsumer() async {
        guard consumerTask == nil else { return }
        let events = serverEventCursor.map { transport.streamEvents(since: $0) } ?? transport.streamEvents()
        consumerTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { break }
                self.apply(event)
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
            try await transport.setConfigOption(configId: configId, value: value)
            if let index = configOptions.firstIndex(where: { $0.id == configId }) {
                configOptions[index].currentValue = value
            }
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    /// Sends the current composer text, if any.
    public func send() async {
        await send(composerText)
    }

    /// Sends a prompt and streams the response into the conversation.
    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        composerText = ""
        errorMessage = nil

        if isSending {
            await enqueueWhileSending(trimmed)
            return
        }

        conversation.append(.user(UserMessage(text: trimmed)))
        conversation.append(.assistant(AssistantMessage(
            turn: AssistantTurn(isGenerating: true, isThinking: true, startedAt: now())
        )))
        isSending = true

        // Events are consumed by the long-lived consumer (started here if it
        // isn't already), so every prompt — first and follow-ups — streams.
        await startConsumer()

        do {
            _ = try await transport.prompt(trimmed)
            await drain()
        } catch {
            await drain()
            errorMessage = serverErrorMessage(error)
            finish(stopReason: nil, outcome: .failed)
            isSending = false
        }
    }

    public func updateQueuedPrompt(id: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await transport.updateQueuedPrompt(id: id, text: trimmed)
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    public func deleteQueuedPrompt(id: String) async {
        do {
            try await transport.deleteQueuedPrompt(id: id)
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    /// Requests cancellation of the in-flight turn.
    public func cancel() async {
        guard isSending else { return }
        try? await transport.cancel()
    }

    /// Switches the session mode.
    public func setMode(_ modeId: String) async {
        try? await transport.setMode(modeId)
        if var state = modeState {
            state.currentModeId = modeId
            modeState = state
        }
    }

    // MARK: - History

    /// Loads the server's conversation snapshot and begins live streaming from
    /// its event cursor.
    public func loadHistory() async {
        do {
            let snapshot = try await transport.snapshot()
            conversation = snapshot.conversation
            queuedPrompts = snapshot.promptQueue
            serverEventCursor = snapshot.eventCursor
            await startConsumer()
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    // MARK: - Streaming

    private var appliedUpdateCount = 0

    /// Yields until the update consumer stops applying buffered updates, so the
    /// final transcript is complete before the turn is marked finished.
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
        case let .userMessageChunk(block, _):
            appendRemoteUserIfNeeded(text: block.textValue ?? "")
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
            // A trailing update for a tool call the finished turn already
            // holds (e.g. a late settle) merges there without reopening it.
            if case let .toolCallUpdate(toolUpdate) = update,
               case .assistant(var message) = conversation.last,
               !message.turn.isGenerating,
               message.turn.toolCalls.contains(where: { $0.toolCallId == toolUpdate.toolCallId }) {
                TranscriptReducer.apply(update, to: &message.turn)
                conversation[conversation.count - 1] = .assistant(message)
                return
            }
            ensureAssistantTurn()
            guard case .assistant(var message) = conversation.last else { return }
            message.turn.isGenerating = true
            isSending = true
            TranscriptReducer.apply(update, to: &message.turn)
            conversation[conversation.count - 1] = .assistant(message)
        }
    }

    private func apply(_ event: ServerSessionStreamEvent) {
        switch event {
        case let .update(update):
            apply(update)
        case let .finished(stopReason):
            finish(stopReason: stopReason, outcome: stopReason == .cancelled ? .cancelled : .completed)
            isSending = false
        case let .failed(message):
            errorMessage = message
            finish(stopReason: nil, outcome: .failed)
            isSending = false
        case let .queueUpdated(queue):
            queuedPrompts = queue
        }
    }

    /// Seeds conversation state for previews. Not for production use.
    public func applyPreviewState(conversation: [ConversationItem], isSending: Bool, usage: SessionUsage? = nil) {
        self.conversation = conversation
        self.isSending = isSending
        self.usage = usage
    }

    /// The single choke point for ending a turn: marks it finished and settles
    /// any tool calls that never received a terminal status, so in-progress
    /// indicators can't outlive the turn.
    private func finish(stopReason: StopReason?, outcome: TranscriptReducer.TurnOutcome) {
        guard case .assistant(var message) = conversation.last else { return }
        message.turn.isGenerating = false
        message.turn.isThinking = false
        message.turn.stopReason = stopReason
        message.turn.endedAt = now()
        TranscriptReducer.settleToolCalls(&message.turn, outcome: outcome)
        conversation[conversation.count - 1] = .assistant(message)
    }

    private func enqueueWhileSending(_ text: String) async {
        do {
            _ = try await transport.prompt(text)
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    private func appendRemoteUserIfNeeded(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if conversation.count >= 2,
           case let .user(user) = conversation[conversation.count - 2],
           case let .assistant(assistant) = conversation.last,
           user.text == trimmed,
           assistant.turn.isGenerating {
            return
        }
        conversation.append(.user(UserMessage(text: text)))
        conversation.append(.assistant(AssistantMessage(
            turn: AssistantTurn(isGenerating: true, isThinking: true, startedAt: now())
        )))
        isSending = true
    }

    private func ensureAssistantTurn() {
        if case let .assistant(message) = conversation.last {
            // A finished turn is never reopened: output arriving after the
            // stopReason means the agent started a new turn on its own (e.g. a
            // background task completing), which gets its own bubble.
            if message.turn.isGenerating { return }
        }
        conversation.append(.assistant(AssistantMessage(
            turn: AssistantTurn(isGenerating: true, isThinking: true, startedAt: now())
        )))
        isSending = true
    }
}
