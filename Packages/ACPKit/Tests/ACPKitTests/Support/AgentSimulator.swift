import Foundation
@testable import ACPKit

/// A test double that plays the agent side of a `MockTransport`: it reads the
/// messages the client sends and responds, and can push notifications and
/// agent-initiated requests back to the client.
actor AgentSimulator {
    private let transport: MockTransport
    private var responders: [String: @Sendable (JSONRPCRequest) -> Result<JSONValue, JSONRPCError>] = [:]
    private(set) var receivedRequests: [JSONRPCRequest] = []
    private(set) var receivedNotifications: [JSONRPCNotification] = []
    private var clientResponses: [JSONRPCResponse] = []
    private var responseWaiters: [CheckedContinuation<JSONRPCResponse, Never>] = []

    init(_ transport: MockTransport) {
        self.transport = transport
    }

    /// Registers a result for a method the client requests.
    func respond(to method: String, result: JSONValue) {
        responders[method] = { _ in .success(result) }
    }

    /// Registers an encodable result for a method the client requests.
    func respond(to method: String, encodable: some Encodable) {
        let value = try! ACPJSON.value(from: encodable)
        responders[method] = { _ in .success(value) }
    }

    /// Registers an error response for a method.
    func fail(_ method: String, with error: JSONRPCError) {
        responders[method] = { _ in .failure(error) }
    }

    func start() {
        Task { await loop() }
    }

    private func loop() async {
        for await data in transport.sent {
            guard let inbound = try? JSONRPCInbound(data: data) else { continue }
            switch inbound {
            case .request(let request):
                receivedRequests.append(request)
                if let responder = responders[request.method] {
                    let response: JSONRPCResponse
                    switch responder(request) {
                    case .success(let value):
                        response = JSONRPCResponse(id: request.id, result: value, error: nil)
                    case .failure(let error):
                        response = JSONRPCResponse(id: request.id, result: nil, error: error)
                    }
                    transport.emit(try! ACPJSON.encoder.encode(response))
                }
            case .response(let response):
                if responseWaiters.isEmpty {
                    clientResponses.append(response)
                } else {
                    responseWaiters.removeFirst().resume(returning: response)
                }
            case .notification(let notification):
                receivedNotifications.append(notification)
            }
        }
    }

    /// Pushes a `session/update` notification to the client.
    func sendUpdate(_ notification: SessionNotification) {
        let params = try! ACPJSON.value(from: notification)
        let message = JSONRPCNotification(method: ACPMethod.sessionUpdate, params: params)
        transport.emit(try! ACPJSON.encoder.encode(message))
    }

    /// Pushes a raw notification to the client.
    func sendRawNotification(method: String, params: JSONValue?) {
        let message = JSONRPCNotification(method: method, params: params)
        transport.emit(try! ACPJSON.encoder.encode(message))
    }

    /// Sends an agent-initiated request to the client and awaits the client's response.
    func requestClient(method: String, id: Int, params: JSONValue?) async -> JSONRPCResponse {
        let request = JSONRPCRequest(id: .number(id), method: method, params: params)
        transport.emit(try! ACPJSON.encoder.encode(request))
        if !clientResponses.isEmpty { return clientResponses.removeFirst() }
        return await withCheckedContinuation { responseWaiters.append($0) }
    }

    /// Returns the methods the client has requested so far.
    func requestedMethods() -> [String] {
        receivedRequests.map(\.method)
    }
}
