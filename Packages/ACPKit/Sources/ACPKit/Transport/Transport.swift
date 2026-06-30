import Foundation

/// A bidirectional message transport for a single ACP peer connection.
///
/// Each element of `incoming` is exactly one decoded JSON-RPC message (one
/// line, newline already stripped). `send` accepts a single encoded JSON-RPC
/// message and is responsible for any framing required by the underlying
/// channel.
public protocol Transport: Sendable {
    /// Sends a single encoded JSON-RPC message.
    func send(_ message: Data) async throws

    /// A stream of inbound JSON-RPC messages, one `Data` per message.
    var incoming: AsyncThrowingStream<Data, any Error> { get }

    /// Closes the transport and terminates the `incoming` stream.
    func close()
}
