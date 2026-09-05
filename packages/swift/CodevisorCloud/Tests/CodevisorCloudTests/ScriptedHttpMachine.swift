import Observation
import CodevisorTestSupport
import Foundation
import CodevisorClient
@testable import CodevisorCloud

// Scripted machine ends for the relay proxy transports, shared by the
// transport round-trip and flow-control suites.

/// Scripts the machine end of "http" channels: decrypts the open, gathers
/// body chunks until `end`, then answers head → chunks → end → close.
@Observable
final class ScriptedHttpMachine: @unchecked Sendable {
  struct ReceivedRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
  }

  struct ScriptedResponse {
    var status: Int
    var headers: [String: String]
    var bodyChunks: [Data]
    var closeReason: CloudChannelCloseReason = .done
    /// Off = leave the channel open after `end` (the live handler closes
    /// immediately; tests that assert on the app's replenish grants keep
    /// it open so late grants can't race the close).
    var sendsClose = true
  }

  private struct OpenPayload: Decodable {
    struct Params: Decodable {
      var method: String
      var path: String
      var headers: [String: String]
    }

    var channelType: String
    var params: Params
  }

  private struct ClientFrame: Decodable {
    var kind: String
    var data: String?
  }

  private struct HeadFrame: Encodable {
    var kind = "head"
    var status: Int
    var headers: [String: String]
  }

  private struct BodyFrame: Encodable {
    var kind: String
    var data: String?
  }

  let machine = ScriptedRelayMachine()
  let scripted: ScriptedCloudHub
  var respond: (@Sendable (ReceivedRequest) -> ScriptedResponse)?
  /// Off = the machine never grants an upload window, so the app's gated
  /// request frames must wait (or time out).
  var grantsUploadWindow = true
  private let lock = NSLock()
  private var requestsByChannel: [String: (params: OpenPayload.Params, body: Data)] = [:]
  private var _channelIds: [String] = []
  private(set) var completedRequests: [ReceivedRequest] = []

  /// Every http channel ever opened, in order (survives completion).
  var openChannelIds: [String] {
    lock.withLock { _channelIds }
  }

  /// Credit envelopes the app has sent toward the machine.
  var creditGrants: [Int] {
    scripted.relayEnvelopes.compactMap {
      if case let .credit(_, _, bytes) = $0.frame { bytes } else { nil }
    }
  }

  func grantUploadWindow(channelId: String, bytes: Int = 1_000_000) {
    scripted.relayToApp(
      machineId: machine.deviceId,
      frame: machine.creditFrame(channelId: channelId, bytes: bytes)
    )
  }

  init() {
    scripted = ScriptedCloudHub(machines: [machine.presence])
    scripted.onRelay = { [weak self] envelope in
      self?.handle(envelope)
    }
  }

  private func handle(_ envelope: ScriptedCloudHub.RelayEnvelope) {
    guard let appKey = scripted.appPublicKey else { return }
    guard let payload = try? machine.receive(envelope.frame, payload: envelope.payload, appPublicKey: appKey)
    else { return }
    let channelId = envelope.frame.channelId
    switch envelope.frame {
    case .open:
      guard let open = try? JSONDecoder().decode(OpenPayload.self, from: payload),
        open.channelType == "http"
      else { return }
      lock.withLock {
        requestsByChannel[channelId] = (open.params, Data())
        _channelIds.append(channelId)
      }
      // Flow-controlled channels: the app's upload gates on our
      // grants, so hand it a window like the live handler does.
      if grantsUploadWindow {
        grantUploadWindow(channelId: channelId)
      }
    case .data:
      guard let frame = try? JSONDecoder().decode(ClientFrame.self, from: payload) else { return }
      switch frame.kind {
      case "chunk":
        guard let encoded = frame.data,
          let chunk = CloudChannelCrypto.base64URLDecode(encoded)
        else { return }
        lock.withLock { requestsByChannel[channelId]?.body.append(chunk) }
      case "end":
        finish(channelId: channelId)
      default:
        break
      }
    case .credit, .close:
      break
    }
  }

  private func finish(channelId: String) {
    guard let pending = lock.withLock({ requestsByChannel.removeValue(forKey: channelId) })
    else { return }
    let request = ReceivedRequest(
      method: pending.params.method,
      path: pending.params.path,
      headers: pending.params.headers,
      body: pending.body
    )
    lock.withLock { completedRequests.append(request) }
    guard let response = respond?(request) else { return }
    let encoder = JSONEncoder()
    func sendJSON(_ value: some Encodable) {
      guard let data = try? encoder.encode(value),
        let sealed = try? machine.sealData(channelId: channelId, payload: data)
      else { return }
      scripted.relayToApp(machineId: machine.deviceId, sealed: sealed)
    }
    if response.status > 0 {
      sendJSON(HeadFrame(status: response.status, headers: response.headers))
      for chunk in response.bodyChunks {
        sendJSON(BodyFrame(kind: "chunk", data: CloudChannelCrypto.base64URLEncode(chunk)))
      }
      sendJSON(BodyFrame(kind: "end", data: nil))
    }
    if response.sendsClose {
      scripted.relayToApp(
        machineId: machine.deviceId,
        frame: machine.closeFrame(channelId: channelId, reason: response.closeReason)
      )
    }
  }
}

/// Scripts the machine end of "ws" channels: remembers accepted opens and
/// lets the test push sealed frames toward the app.
@Observable
final class ScriptedWsMachine: @unchecked Sendable {
  let machine = ScriptedRelayMachine()
  let scripted: ScriptedCloudHub
  private let lock = NSLock()
  private var _openChannelIds: [String] = []

  init() {
    scripted = ScriptedCloudHub(machines: [machine.presence])
    scripted.onRelay = { [weak self] envelope in
      guard let self, let appKey = self.scripted.appPublicKey else { return }
      guard
        (try? self.machine.receive(envelope.frame, payload: envelope.payload, appPublicKey: appKey)) != nil
      else { return }
      if case .open = envelope.frame {
        self.lock.withLock { self._openChannelIds.append(envelope.frame.channelId) }
        // Grant the app's send window like the live handler does.
        self.scripted.relayToApp(
          machineId: self.machine.deviceId,
          frame: self.machine.creditFrame(
            channelId: envelope.frame.channelId, bytes: 1_000_000)
        )
      }
    }
  }

  var openChannelId: String? { lock.withLock { _openChannelIds.first } }

  func push(_ json: String) {
    guard let channelId = openChannelId,
      let sealed = try? machine.sealData(channelId: channelId, payload: Data(json.utf8))
    else { return }
    scripted.relayToApp(machineId: machine.deviceId, sealed: sealed)
  }
}

/// One test hub wired to a scripted machine's socket, plus its relay endpoint.
func makeRelayEndpoint(
  scripted: ScriptedCloudHub,
  machine: ScriptedRelayMachine
) -> (endpoint: CloudRelayEndpoint, hub: CloudHubConnection) {
  let hub = CloudHubConnection(
    serverURL: URL(string: "https://cloud.example.com")!,
    credentialStore: InMemoryCloudCredentialStore(token: "session-token"),
    deviceName: "Test App",
    deviceOS: "macOS",
    webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
    readyTimeout: .seconds(2),
    sleep: TestClock().sleep,
    reconnectDelay: { _ in .zero }
  )
  let endpoint = CloudRelayEndpoint(
    hub: hub,
    machineDeviceId: machine.deviceId,
    machinePublicKey: machine.publicKey
  )
  return (endpoint, hub)
}

func relayMessageText(_ message: ServerWebSocketMessage) -> String? {
  if case let .string(value) = message { return value }
  return nil
}

func relayMessageBinary(_ message: ServerWebSocketMessage) -> Data? {
  if case let .data(value) = message { return value }
  return nil
}
