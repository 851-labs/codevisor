import Foundation

/// An in-memory `Transport` for tests and SwiftUI previews.
///
/// Outbound messages sent by the client are captured and exposed via `sent`.
/// The counterpart (a simulated agent) injects inbound messages with `emit`.
public final class MockTransport: Transport, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, any Error>
    private let incomingContinuation: AsyncThrowingStream<Data, any Error>.Continuation

    /// A stream of messages the client sent outbound.
    public let sent: AsyncStream<Data>
    private let sentContinuation: AsyncStream<Data>.Continuation

    private let lock = NSLock()
    private var closed = false

    public init() {
        (incoming, incomingContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
        (sent, sentContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    public func send(_ message: Data) async throws {
        try recordSend(message)
    }

    private func recordSend(_ message: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if closed { throw ACPError.connectionClosed }
        sentContinuation.yield(message)
    }

    /// Injects an inbound message as if it came from the agent.
    public func emit(_ data: Data) {
        incomingContinuation.yield(data)
    }

    /// Injects an inbound message encoded from an `Encodable` value.
    public func emit(_ value: some Encodable) throws {
        emit(try ACPJSON.encoder.encode(value))
    }

    /// Finishes the inbound stream, signalling the agent closed the connection.
    public func finishIncoming() {
        incomingContinuation.finish()
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        incomingContinuation.finish()
        sentContinuation.finish()
    }
}
