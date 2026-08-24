import Foundation
import CodevisorClient

extension CloudHubConnection {
    private struct HelloMessage: Encodable {
        struct Device: Encodable {
            var deviceId: String
            var kind: String
            var name: String
            var os: String
            var appVersion: String?
            var publicKey: String
        }

        var t = "hello"
        var protocolVersion = CloudHubConnection.protocolVersion
        var device: Device

        enum CodingKeys: String, CodingKey {
            case t
            case protocolVersion = "protocol"
            case device
        }
    }

    private struct RelayHeader: Encodable {
        var machineId: String
        var frame: CloudRelayFrame
    }

    func sendHello(identity: CloudAppDeviceIdentity) throws {
        let hello = HelloMessage(
            device: HelloMessage.Device(
                deviceId: identity.deviceId,
                kind: "app",
                name: deviceName,
                os: deviceOS,
                appVersion: appVersion,
                publicKey: identity.publicKey
            ))
        try enqueueSend(hello)
    }

    /// Sends one protocol ping and arms a bounded pong deadline. A half-open
    /// URLSession socket does not necessarily make `receive()` throw, so the
    /// deadline explicitly tears it down and lets the run loop reconnect.
    func sendKeepalivePing(on expectedSocketID: UUID) {
        guard socketID == expectedSocketID, isWelcomed else { return }
        struct Ping: Encodable {
            var t = "ping"
        }
        awaitingPongOnSocketID = expectedSocketID
        heartbeatTimeoutTask?.cancel()
        let timeout = heartbeatTimeout
        heartbeatTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.expireHeartbeat(on: expectedSocketID)
        }
        do {
            try enqueueSend(Ping())
        } catch {
            handleSocketFailure(on: expectedSocketID, error: error)
        }
    }

    func receivePong() {
        guard awaitingPongOnSocketID == socketID else { return }
        heartbeatTimeoutTask?.cancel()
        heartbeatTimeoutTask = nil
        awaitingPongOnSocketID = nil
    }

    private func expireHeartbeat(on expectedSocketID: UUID) {
        guard socketID == expectedSocketID,
            awaitingPongOnSocketID == expectedSocketID
        else { return }
        handleSocketFailure(on: expectedSocketID, error: CloudHubConnectionError.timedOut)
    }

    func resetHeartbeat() {
        heartbeatTimeoutTask?.cancel()
        heartbeatTimeoutTask = nil
        awaitingPongOnSocketID = nil
    }

    private func handleSocketFailure(on expectedSocketID: UUID, error: any Error) {
        guard socketID == expectedSocketID else { return }
        Log.cloud.error(
            "Cloud hub socket is unhealthy; reconnecting: \(String(describing: error), privacy: .public)"
        )
        isWelcomed = false
        resetHeartbeat()
        failAllChannels()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// Sends one relay frame as a binary envelope message (ciphertext rides
    /// beside the JSON header; credit/close carry an empty payload).
    func sendRelay(machineId: String, frame: CloudRelayFrame, payload: Data = Data()) throws {
        guard socket != nil else { throw CloudHubConnectionError.disconnected }
        let header = try encoder.encode(RelayHeader(machineId: machineId, frame: frame))
        try enqueueSend(.data(CloudRelayWire.encode([CloudRelayEnvelope(header: header, payload: payload)])))
    }

    private func enqueueSend(_ message: some Encodable) throws {
        try enqueueSend(.string(String(decoding: try encoder.encode(message), as: UTF8.self)))
    }

    /// Chained sends keep wire order aligned with seq allocation order —
    /// concurrent senders must not overtake each other between allocating a
    /// seq and the frame reaching the socket.
    private func enqueueSend(_ message: ServerWebSocketMessage) throws {
        guard let socket, let socketID else { throw CloudHubConnectionError.disconnected }
        sendChain = Task { [weak self, previous = sendChain] in
            await previous.value
            do {
                try await socket.send(message)
            } catch {
                await self?.handleSocketFailure(on: socketID, error: error)
            }
        }
    }
}
