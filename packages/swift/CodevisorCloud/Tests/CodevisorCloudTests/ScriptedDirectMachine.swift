import CodevisorTestSupport
import Observation
import Foundation
import CodevisorClient
@testable import CodevisorCloud

/// The machine end of a direct pipe for tests: answers hello with the direct
/// welcome (no machine list — the wire shape DirectChannelHost sends), pongs
/// pings, and runs relay envelopes through a `ScriptedRelayMachine`'s
/// responder crypto. Every frame the app sends is recorded, and `onFrame`
/// sees each one the responder accepted (synchronously, in send order).
@Observable
final class ScriptedDirectMachine: @unchecked Sendable {
  /// One app→machine frame the responder accepted: the header, its
  /// decrypted payload (open/data frames), and the sealed payload size.
  struct ReceivedFrame {
    var frame: CloudRelayFrame
    var plaintext: Data?
    var sealedBytes: Int
  }

  let machine: ScriptedRelayMachine
  let socket = FakeWebSocketConnection()
  private let lock = NSLock()
  private var helloPublicKey: String?
  var acceptsHello = true
  var respondsToPing = true
  var onFrame: (@Sendable (ReceivedFrame) -> Void)?
  private(set) var pingCount = 0
  private var receivedFrames: [CloudRelayFrame] = []

  private struct RelayHeader: Codable {
    var machineId: String
    var frame: CloudRelayFrame
  }

  init(machine: ScriptedRelayMachine = ScriptedRelayMachine()) {
    self.machine = machine
    socket.onSend = { [weak self] message in
      self?.handle(message)
    }
  }

  var appPublicKey: String? {
    lock.withLock { helloPublicKey }
  }

  /// Every frame the app has sent, in order.
  var frames: [CloudRelayFrame] {
    lock.withLock { receivedFrames }
  }

  var credits: [(channelId: String, seq: UInt64, bytes: Int)] {
    frames.compactMap {
      if case let .credit(channelId, seq, bytes) = $0 { (channelId, seq, bytes) } else { nil }
    }
  }

  var pings: Int {
    lock.withLock { pingCount }
  }

  func sendToApp(frame: CloudRelayFrame, payload: Data = Data()) {
    let header = try! JSONEncoder().encode(
      RelayHeader(machineId: machine.deviceId, frame: frame))
    socket.push(.data(CloudRelayWire.encode([CloudRelayEnvelope(header: header, payload: payload)])))
  }

  func sendToApp(sealed: (frame: CloudRelayFrame, payload: Data)) {
    sendToApp(frame: sealed.frame, payload: sealed.payload)
  }

  private func handle(_ message: ServerWebSocketMessage) {
    switch message {
    case let .data(binary):
      guard let envelopes = try? CloudRelayWire.decode(binary) else { return }
      for wire in envelopes {
        guard let header = try? JSONDecoder().decode(RelayHeader.self, from: wire.header),
          header.machineId == machine.deviceId,
          let appKey = appPublicKey
        else { continue }
        lock.withLock { receivedFrames.append(header.frame) }
        // A frame the responder cannot open (bad seq, bad seal) is
        // dropped, as a real machine would.
        let plaintext: Data?
        do {
          plaintext = try machine.receive(header.frame, payload: wire.payload, appPublicKey: appKey)
        } catch {
          continue
        }
        onFrame?(ReceivedFrame(frame: header.frame, plaintext: plaintext, sealedBytes: wire.payload.count))
      }
    case let .string(text):
      let data = Data(text.utf8)
      struct Probe: Decodable {
        var t: String
      }
      guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return }
      switch probe.t {
      case "hello":
        struct Hello: Decodable {
          struct Device: Decodable {
            var publicKey: String
          }

          var device: Device
        }
        guard acceptsHello, let hello = try? JSONDecoder().decode(Hello.self, from: data)
        else { return }
        lock.withLock { helloPublicKey = hello.device.publicKey }
        socket.pushJSON(#"{"t":"welcome","protocol":2,"connectionId":"direct-1"}"#)
      case "ping":
        lock.withLock { pingCount += 1 }
        if respondsToPing {
          socket.pushJSON(#"{"t":"pong"}"#)
        }
      default:
        break
      }
    }
  }
}

func makeDirectConnection(
  to scripted: ScriptedDirectMachine,
  directURL: URL = URL(string: "ws://192.168.1.20:4931/v1/direct")!,
  readyTimeout: Duration = .seconds(2),
  heartbeatInterval: Duration = .seconds(60),
  heartbeatTimeout: Duration = .seconds(5),
  clock: TestClock = TestClock(),
  onDown: (@Sendable () -> Void)? = nil
) -> CloudDirectConnection {
  CloudDirectConnection(
    directURL: directURL,
    machineDeviceId: scripted.machine.deviceId,
    machinePublicKey: scripted.machine.publicKey,
    credentialStore: InMemoryCloudCredentialStore(),
    webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
    readyTimeout: readyTimeout,
    heartbeatInterval: heartbeatInterval,
    heartbeatTimeout: heartbeatTimeout,
    onDown: onDown,
    sleep: clock.sleep
  )
}

/// A channel transport over one direct pipe to a scripted machine — the
/// harness for the generic channel adapters (HTTP, WebSocket, loopback).
func makeDirectEndpoint(
  to scripted: ScriptedDirectMachine,
  readyTimeout: Duration = .seconds(2),
  clock: TestClock = TestClock()
) -> (endpoint: CloudDirectTransport, connection: CloudDirectConnection) {
  let connection = makeDirectConnection(to: scripted, readyTimeout: readyTimeout, clock: clock)
  return (CloudDirectTransport(connection: connection), connection)
}
