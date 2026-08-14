import Foundation

/// A summary of an agent-side session, as returned by the server's session
/// listing (originally ACP `session/list`).
public struct SessionInfo: Sendable, Codable, Equatable, Identifiable {
    public var sessionId: String
    public var cwd: String
    public var title: String?
    public var updatedAt: String?

    public var id: String { sessionId }

    public init(sessionId: String, cwd: String, title: String? = nil, updatedAt: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
    }
}
