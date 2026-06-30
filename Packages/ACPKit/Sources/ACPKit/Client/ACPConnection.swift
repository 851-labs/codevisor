import Foundation

/// Handles inbound JSON-RPC requests and notifications for a connection.
public protocol ACPConnectionHandler: AnyObject, Sendable {
    /// Handles an inbound request, returning the result value or throwing a
    /// `JSONRPCError`.
    func handleRequest(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError>
    /// Handles an inbound notification. Notifications are delivered in order.
    func handleNotification(method: String, params: JSONValue?) async
}

/// A bidirectional JSON-RPC 2.0 peer over a `Transport`.
///
/// Correlates outbound requests with their responses, dispatches inbound
/// notifications in order, and routes inbound requests to a handler.
public actor ACPConnection {
    private let transport: any Transport
    private weak var handler: (any ACPConnectionHandler)?

    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONRPCResponse, any Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var isClosed = false

    public init(transport: any Transport) {
        self.transport = transport
    }

    /// Sets the handler for inbound requests/notifications and begins the read loop.
    public func start(handler: any ACPConnectionHandler) {
        self.handler = handler
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Sends a request and awaits its response value, throwing on RPC error.
    public func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        if isClosed { throw ACPError.connectionClosed }
        let id = nextId
        nextId += 1
        let message = JSONRPCRequest(id: .number(id), method: method, params: params)
        let data = try ACPJSON.encoder.encode(message)

        let response: JSONRPCResponse = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [transport] in
                do {
                    try await transport.send(data)
                } catch {
                    self.failPending(id: id, error: error)
                }
            }
        }

        if let error = response.error { throw ACPError.rpc(error) }
        return response.result ?? .null
    }

    /// Sends a notification (no response expected).
    public func notify(_ method: String, params: JSONValue?) async throws {
        if isClosed { throw ACPError.connectionClosed }
        let message = JSONRPCNotification(method: method, params: params)
        let data = try ACPJSON.encoder.encode(message)
        try await transport.send(data)
    }

    /// Closes the connection and fails any pending requests.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        readTask?.cancel()
        readTask = nil
        transport.close()
        failAllPending(error: ACPError.connectionClosed)
    }

    // MARK: - Read loop

    private func readLoop() async {
        do {
            for try await data in transport.incoming {
                await dispatch(data)
            }
            failAllPending(error: ACPError.connectionClosed)
        } catch {
            failAllPending(error: error)
        }
    }

    private func dispatch(_ data: Data) async {
        guard let inbound = try? JSONRPCInbound(data: data) else { return }
        switch inbound {
        case .response(let response):
            resume(response)
        case .notification(let notification):
            await handler?.handleNotification(method: notification.method, params: notification.params)
        case .request(let request):
            // Handle inbound requests off the read loop so a slow handler (e.g.
            // awaiting a UI permission decision) does not stall notifications.
            Task { [weak self] in
                await self?.serviceRequest(request)
            }
        }
    }

    private func serviceRequest(_ request: JSONRPCRequest) async {
        let result = await handler?.handleRequest(method: request.method, params: request.params)
            ?? .failure(.methodNotFound(request.method))
        let response: JSONRPCResponse
        switch result {
        case .success(let value):
            response = JSONRPCResponse(id: request.id, result: value, error: nil)
        case .failure(let error):
            response = JSONRPCResponse(id: request.id, result: nil, error: error)
        }
        if let data = try? ACPJSON.encoder.encode(response) {
            try? await transport.send(data)
        }
    }

    private func resume(_ response: JSONRPCResponse) {
        guard case .number(let id) = response.id else { return }
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: response)
    }

    private func failPending(id: Int, error: any Error) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func failAllPending(error: any Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
