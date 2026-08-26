import Foundation

/// A machine the app knows about but cannot currently reach — a cloud
/// machine whose relay isn't connected yet (launch-time roster still
/// loading, account signed out, relay down).
public struct MachineUnreachableError: LocalizedError, Sendable {
    public let machineId: String

    public init(machineId: String) {
        self.machineId = machineId
    }

    public var errorDescription: String? {
        "This machine isn't reachable right now. Check its connection and try again."
    }
}

/// Transports that fail every request with `MachineUnreachableError`.
///
/// `client(for:)` hands these out instead of falling back to ANOTHER
/// machine's transport when a machine id can't be resolved yet: a silent
/// fallback answers with the wrong machine's data, which downstream caches
/// then persist under the requested machine's key.
struct UnreachableRequestTransport: ServerRequestTransport {
    let machineId: String

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw MachineUnreachableError(machineId: machineId)
    }

    func stream(
        for request: URLRequest
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        throw MachineUnreachableError(machineId: machineId)
    }
}

struct UnreachableWebSocketTransport: ServerWebSocketTransport {
    let machineId: String

    func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
        UnreachableWebSocketConnection(machineId: machineId)
    }
}

private final class UnreachableWebSocketConnection: ServerWebSocketConnecting, @unchecked Sendable {
    private let machineId: String

    init(machineId: String) {
        self.machineId = machineId
    }

    func send(_ message: ServerWebSocketMessage) async throws {
        throw MachineUnreachableError(machineId: machineId)
    }

    func receive() async throws -> ServerWebSocketMessage {
        throw MachineUnreachableError(machineId: machineId)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    var closeCode: URLSessionWebSocketTask.CloseCode { .abnormalClosure }
}

extension CodevisorServerConfig {
    /// A config whose every request fails with `MachineUnreachableError` —
    /// for machine ids the app recognizes but can't route yet.
    public static func unreachable(machineId: String) -> CodevisorServerConfig {
        CodevisorServerConfig(
            baseURL: URL(string: "http://unreachable.invalid")!,
            bearerToken: nil,
            requestTransport: UnreachableRequestTransport(machineId: machineId),
            webSocketTransport: UnreachableWebSocketTransport(machineId: machineId)
        )
    }
}
