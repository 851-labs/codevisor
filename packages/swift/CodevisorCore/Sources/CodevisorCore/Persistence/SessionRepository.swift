import Foundation

/// Persists and retrieves chat sessions.
public protocol SessionRepository: Sendable {
    func load() -> [ChatSession]
    func save(_ sessions: [ChatSession])
}

/// File/in-memory backed session repository.
public struct DefaultSessionRepository: SessionRepository {
    private let repository: CodableRepository<ChatSession>

    public init(store: any PersistenceStore) {
        self.repository = CodableRepository(
            store: store,
            key: "sessions",
            corruptionTitle: "Couldn't Read Your Saved Sessions"
        )
    }

    public func load() -> [ChatSession] { repository.load() }
    public func save(_ sessions: [ChatSession]) { repository.save(sessions) }
}
