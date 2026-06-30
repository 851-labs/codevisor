import Foundation

/// `fs/read_text_file` request params.
public struct ReadTextFileRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var path: String
    public var line: UInt32?
    public var limit: UInt32?

    public init(sessionId: String, path: String, line: UInt32? = nil, limit: UInt32? = nil) {
        self.sessionId = sessionId
        self.path = path
        self.line = line
        self.limit = limit
    }
}

/// `fs/read_text_file` response.
public struct ReadTextFileResponse: Sendable, Codable, Equatable {
    public var content: String

    public init(content: String) {
        self.content = content
    }
}

/// `fs/write_text_file` request params.
public struct WriteTextFileRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var path: String
    public var content: String

    public init(sessionId: String, path: String, content: String) {
        self.sessionId = sessionId
        self.path = path
        self.content = content
    }
}
