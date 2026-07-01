import Foundation

/// Errors surfaced by the ACP client layer.
public enum ACPError: Error, Equatable, Sendable {
    /// The transport closed before a pending request received a response.
    case connectionClosed
    /// A response carried an id that did not correspond to a pending request,
    /// or had an unexpected shape.
    case malformedResponse
    /// The peer returned a JSON-RPC error.
    case rpc(JSONRPCError)
}
