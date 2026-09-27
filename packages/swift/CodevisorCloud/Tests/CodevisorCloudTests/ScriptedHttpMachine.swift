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
  let scripted: ScriptedDirectMachine
  var respond: (@Sendable (ReceivedRequest) -> ScriptedResponse)?
  /// Off = the machine never grants an upload window, so the app's gated
  /// request frames must wait (or time out).
  var grantsUploadWindow = true
  private let lock = NSLock()
  private var requestsByChannel: [String: (params: OpenPayload.Params, body: Data)] = [:]
  private var _channelIds: [String] = []
  private var _receivedBodyBytes: [String: Int] = [:]
  private(set) var completedRequests: [ReceivedRequest] = []

  /// Request body bytes that have arrived on a channel so far.
  func receivedBodyBytes(channelId: String) -> Int {
    lock.withLock { _receivedBodyBytes[channelId, default: 0] }
  }

  /// Every http channel ever opened, in order (survives completion).
  var openChannelIds: [String] {
    lock.withLock { _channelIds }
  }

  /// Credit envelopes the app has sent toward the machine.
  var creditGrants: [Int] {
    scripted.credits.map(\.bytes)
  }

  func grantUploadWindow(channelId: String, bytes: Int = 1_000_000) {
    scripted.sendToApp(frame: machine.creditFrame(channelId: channelId, bytes: bytes))
  }

  init() {
    scripted = ScriptedDirectMachine(machine: machine)
    scripted.onFrame = { [weak self] received in
      self?.handle(received)
    }
  }

  private func handle(_ received: ScriptedDirectMachine.ReceivedFrame) {
    guard let payload = received.plaintext else { return }
    let channelId = received.frame.channelId
    switch received.frame {
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
        lock.withLock {
          requestsByChannel[channelId]?.body.append(chunk)
          _receivedBodyBytes[channelId, default: 0] += chunk.count
        }
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
      scripted.sendToApp(sealed: sealed)
    }
    if response.status > 0 {
      sendJSON(HeadFrame(status: response.status, headers: response.headers))
      for chunk in response.bodyChunks {
        sendJSON(BodyFrame(kind: "chunk", data: CloudChannelCrypto.base64URLEncode(chunk)))
      }
      sendJSON(BodyFrame(kind: "end", data: nil))
    }
    if response.sendsClose {
      scripted.sendToApp(frame: machine.closeFrame(channelId: channelId, reason: response.closeReason))
    }
  }
}

/// Scripts the machine end of "ws" channels: remembers accepted opens and
/// lets the test push sealed frames toward the app.
@Observable
final class ScriptedWsMachine: @unchecked Sendable {
  let machine = ScriptedRelayMachine()
  let scripted: ScriptedDirectMachine
  private let lock = NSLock()
  private var _openChannelIds: [String] = []

  init() {
    scripted = ScriptedDirectMachine(machine: machine)
    scripted.onFrame = { [weak self] received in
      guard let self, case let .open(channelId, _, _) = received.frame else { return }
      self.lock.withLock { self._openChannelIds.append(channelId) }
      // Grant the app's send window like the live handler does.
      self.scripted.sendToApp(frame: self.machine.creditFrame(channelId: channelId, bytes: 1_000_000))
    }
  }

  var openChannelId: String? { lock.withLock { _openChannelIds.first } }

  func push(_ json: String) {
    guard let channelId = openChannelId,
      let sealed = try? machine.sealData(channelId: channelId, payload: Data(json.utf8))
    else { return }
    scripted.sendToApp(sealed: sealed)
  }
}

func relayMessageText(_ message: ServerWebSocketMessage) -> String? {
  if case let .string(value) = message { return value }
  return nil
}

func relayMessageBinary(_ message: ServerWebSocketMessage) -> Data? {
  if case let .data(value) = message { return value }
  return nil
}
