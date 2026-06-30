import Foundation

/// A JSON-RPC 2.0 error object.
public struct JSONRPCError: Sendable, Codable, Equatable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC error codes.
    public static func parseError(_ message: String = "Parse error") -> JSONRPCError {
        JSONRPCError(code: -32700, message: message)
    }

    public static func invalidRequest(_ message: String = "Invalid request") -> JSONRPCError {
        JSONRPCError(code: -32600, message: message)
    }

    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }

    public static func invalidParams(_ message: String = "Invalid params") -> JSONRPCError {
        JSONRPCError(code: -32602, message: message)
    }

    public static func internalError(_ message: String = "Internal error") -> JSONRPCError {
        JSONRPCError(code: -32603, message: message)
    }

    /// ACP cooperative cancellation error code.
    public static func requestCancelled(_ message: String = "Request cancelled") -> JSONRPCError {
        JSONRPCError(code: -32800, message: message)
    }
}
