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
      var tunnelEndpointId: String?
      var releaseChannel: String
      var tunnelOnly = true
    }

    var t = "hello"
    var protocolVersion = CloudHubConnection.protocolVersion
    var device: Device
    var resume: String?

    enum CodingKeys: String, CodingKey {
      case t
      case protocolVersion = "protocol"
      case device
      case resume
    }
  }

  static func connectRequest(url: URL, identity: CloudAppDeviceIdentity) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpShouldHandleCookies = false
    request.setValue(
      CloudTunnelIdentity.endpointId(for: identity), forHTTPHeaderField: "x-codevisor-tunnel-endpoint")
    return request
  }

  func sendHello(identity: CloudAppDeviceIdentity) throws {
    let hello = HelloMessage(
      device: HelloMessage.Device(
        deviceId: identity.deviceId,
        kind: "app",
        name: deviceName,
        os: deviceOS,
        appVersion: appVersion,
        publicKey: identity.publicKey,
        tunnelEndpointId: CloudTunnelIdentity.endpointId(for: identity),
        releaseChannel: releaseChannel.wireValue
      ),
      resume: resumeToken
    )
    try enqueueSend(hello)
  }

  func sendKeepalivePing(on expectedSocketID: UUID) {
    guard socketID == expectedSocketID, isWelcomed else { return }
    struct Ping: Encodable {
      var t = "ping"
    }
    awaitingPongOnSocketID = expectedSocketID
    heartbeatTimeoutTask?.cancel()
    let timeout = heartbeatTimeout
    let sleep = sleep
    heartbeatTimeoutTask = Task { [weak self] in
      try? await sleep(timeout)
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
    socket?.cancel(with: .goingAway, reason: nil)
  }

  private func enqueueSend(_ message: some Encodable) throws {
    guard let socket, let socketID else { throw CloudHubConnectionError.disconnected }
    let message = ServerWebSocketMessage.string(String(decoding: try encoder.encode(message), as: UTF8.self))
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
