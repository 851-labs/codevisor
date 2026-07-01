import Foundation
import ACPKit

public struct ServerSessionSnapshot: Equatable, Sendable {
    public var conversation: [ConversationItem]
    public var eventCursor: Int
}

public enum ServerSessionStreamEvent: Equatable, Sendable {
    case update(SessionUpdate)
    case finished(StopReason)
    case failed(String)
}

public struct ServerSessionTransport: Sendable {
    public static let liveOnlyEventCursor = 9_007_199_254_740_991

    private let client: any HerdManServerClienting
    private let sessionId: UUID

    public init(client: any HerdManServerClienting, sessionId: UUID) {
        self.client = client
        self.sessionId = sessionId
    }

    public func prompt(_ text: String) async throws -> ServerPromptAccepted {
        try await client.promptSession(id: sessionId, text: text)
    }

    public func cancel() async throws {
        try await client.cancelSession(id: sessionId)
    }

    public func setMode(_ modeId: String) async throws {
        try await client.setSessionMode(id: sessionId, modeId: modeId)
    }

    public func setConfigOption(configId: String, value: String) async throws {
        try await client.setSessionConfig(id: sessionId, configId: configId, value: value)
    }

    public func snapshot() async throws -> ServerSessionSnapshot {
        let detail = try await client.sessionDetail(id: sessionId)
        return ServerSessionSnapshot(
            conversation: Self.conversationItems(from: detail.conversation),
            eventCursor: detail.eventCursor
        )
    }

    public func updates(since: Int = Self.liveOnlyEventCursor) -> AsyncStream<SessionUpdate> {
        AsyncStream { continuation in
            let task = Task {
                for await streamEvent in streamEvents(since: since) {
                    guard case let .update(update) = streamEvent else { continue }
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func streamEvents(since: Int = Self.liveOnlyEventCursor) -> AsyncStream<ServerSessionStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await event in client.eventStream(since: since) {
                        guard event.subjectId.caseInsensitiveCompare(sessionId.uuidString) == .orderedSame else {
                            continue
                        }
                        for update in Self.sessionStreamEvents(from: event) {
                            continuation.yield(update)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func conversationItems(from items: [ServerConversationItem]) -> [ConversationItem] {
        var conversation: [ConversationItem] = []
        var pendingAssistant: AssistantMessage?

        func flushAssistant() {
            if let assistant = pendingAssistant {
                conversation.append(.assistant(assistant))
                pendingAssistant = nil
            }
        }

        for item in items {
            switch item.role {
            case .user:
                flushAssistant()
                conversation.append(.user(UserMessage(id: uuid(from: item.id), text: item.text)))
            case .assistant:
                var assistant = pendingAssistant ?? AssistantMessage(
                    id: uuid(from: item.id),
                    turn: AssistantTurn(isGenerating: item.isGenerating)
                )
                TranscriptReducer.apply(.agentMessageChunk(.text(item.text)), to: &assistant.turn)
                assistant.turn.isGenerating = item.isGenerating
                pendingAssistant = assistant
            case .system:
                flushAssistant()
            }
        }
        flushAssistant()
        return conversation
    }

    private static func uuid(from id: String) -> UUID {
        UUID(uuidString: id) ?? UUID()
    }

    private static func sessionStreamEvents(from event: ServerEventEnvelope) -> [ServerSessionStreamEvent] {
        if let rawUpdate = decodeRawSessionUpdate(event.payload) {
            return [.update(rawUpdate)]
        }

        switch event.kind {
        case "session.output":
            return textUpdates(from: event.payload).map(ServerSessionStreamEvent.update)
        case "session.updated":
            if let stopReason = stopReason(from: event.payload) {
                return [.finished(stopReason)]
            }
            return metadataUpdates(from: event.payload).map(ServerSessionStreamEvent.update)
        case "session.error":
            return [.failed(errorMessage(from: event.payload))]
        default:
            return []
        }
    }

    private static func decodeRawSessionUpdate(_ payload: JSONValue) -> SessionUpdate? {
        guard payload["sessionUpdate"] != nil else { return nil }
        do {
            let data = try JSONEncoder().encode(payload)
            return try JSONDecoder().decode(SessionUpdate.self, from: data)
        } catch {
            return nil
        }
    }

    private static func textUpdates(from payload: JSONValue) -> [SessionUpdate] {
        guard let role = payload["role"]?.stringValue,
              let text = payload["text"]?.stringValue,
              !text.isEmpty else {
            return []
        }
        switch role {
        case "assistant":
            return [.agentMessageChunk(.text(text))]
        case "user":
            return [.userMessageChunk(.text(text))]
        default:
            return []
        }
    }

    private static func metadataUpdates(from payload: JSONValue) -> [SessionUpdate] {
        if let configOptions = decodeConfigOptions(payload["configOptions"]) {
            return [.configOptionUpdate(configOptions)]
        }
        if let modeId = payload["modeId"]?.stringValue {
            return [.currentModeUpdate(currentModeId: modeId)]
        }
        return []
    }

    private static func stopReason(from payload: JSONValue) -> StopReason? {
        guard let raw = payload["stopReason"]?.stringValue else { return nil }
        return StopReason(rawValue: raw)
    }

    private static func errorMessage(from payload: JSONValue) -> String {
        payload["message"]?.stringValue ?? "The server reported an error."
    }

    private static func decodeConfigOptions(_ value: JSONValue?) -> [SessionConfigOption]? {
        guard let value else { return nil }
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode([SessionConfigOption].self, from: data)
        } catch {
            return nil
        }
    }
}
