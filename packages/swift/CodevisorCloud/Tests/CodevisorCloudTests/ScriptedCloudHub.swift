import CodevisorTestSupport
import Observation
import Foundation
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

// MARK: - Fake WebSocket seam

/// A fake hub (and optionally a scripted responder machine behind it) living
/// on the other end of a FakeWebSocketConnection: answers `hello` with
/// `welcome` and hands relay envelopes to `onRelay`.
@Observable
final class ScriptedCloudHub: @unchecked Sendable {
  struct RelayEnvelope {
    var machineId: String
    var frame: CloudRelayFrame
    var payload: Data
  }

  private struct RelayHeader: Codable {
    var machineId: String
    var frame: CloudRelayFrame
  }

  private let lock = NSLock()
  private var scriptedSockets: [FakeWebSocketConnection] = []
  let machines: [CloudMachine]
  private var relayed: [RelayEnvelope] = []
  /// Called (synchronously, in send order) for every relay envelope the app
  /// sends. Push responses through `relayToApp`.
  var onRelay: (@Sendable (RelayEnvelope) -> Void)?
  private(set) var sawHello = false
  var appPublicKey: String?
  var respondsToPing = true
  /// Session resume scripting: when true, welcomes carry rotating resume
  /// tokens and a hello presenting the current token resumes (same
  /// connection id + resumed flag) — unless `acceptResume` is off.
  var issueResumeTokens = false
  var acceptResume = true
  private var issuedToken: String?
  private var connectionCounter = 0
  private var currentConnectionId = "conn-0"

  init(machines: [CloudMachine] = []) {
    self.machines = machines
  }

  /// The first scripted socket (created lazily so single-socket tests can
  /// hand it to a transport before connecting).
  var socket: FakeWebSocketConnection {
    lock.withLock {
      if scriptedSockets.isEmpty { scriptedSockets.append(wireSocket()) }
      return scriptedSockets[0]
    }
  }

  /// The socket the hub currently speaks through (reconnects switch it).
  var currentSocket: FakeWebSocketConnection {
    lock.withLock { scriptedSockets.last ?? scriptedSockets[0] }
  }

  /// A fresh scripted socket for reconnect tests; wire the transport with
  /// `FakeWebSocketTransport { _ in scripted.makeSocket() }`.
  func makeSocket() -> FakeWebSocketConnection {
    lock.withLock {
      let socket = wireSocket()
      scriptedSockets.append(socket)
      return socket
    }
  }

  private func wireSocket() -> FakeWebSocketConnection {
    let socket = FakeWebSocketConnection()
    socket.onSend = { [weak self] message in
      self?.handle(message)
    }
    return socket
  }

  var relayEnvelopes: [RelayEnvelope] {
    lock.withLock { relayed }
  }

  func relayToApp(machineId: String, frame: CloudRelayFrame, payload: Data = Data()) {
    let header = try! JSONEncoder().encode(RelayHeader(machineId: machineId, frame: frame))
    currentSocket.push(
      .data(CloudRelayWire.encode([CloudRelayEnvelope(header: header, payload: payload)]))
    )
  }

  func relayToApp(machineId: String, sealed: (frame: CloudRelayFrame, payload: Data)) {
    relayToApp(machineId: machineId, frame: sealed.frame, payload: sealed.payload)
  }

  func presenceToApp(_ machine: CloudMachine) {
    struct Envelope: Encodable {
      var t = "presence"
      var machine: CloudMachine
    }
    let data = try! JSONEncoder().encode(Envelope(machine: machine))
    currentSocket.push(.string(String(decoding: data, as: UTF8.self)))
  }

  func machineResetToApp(machineId: String) {
    struct Envelope: Encodable {
      var t = "machine-reset"
      var machineId: String
    }
    let data = try! JSONEncoder().encode(Envelope(machineId: machineId))
    currentSocket.push(.string(String(decoding: data, as: UTF8.self)))
  }

  func errorToApp(
    code: String,
    message: String,
    machineId: String? = nil,
    channelId: String? = nil
  ) {
    struct Envelope: Encodable {
      var t = "error"
      var code: String
      var message: String
      var machineId: String?
      var channelId: String?
    }
    let data = try! JSONEncoder().encode(
      Envelope(
        code: code,
        message: message,
        machineId: machineId,
        channelId: channelId
      ))
    currentSocket.push(.string(String(decoding: data, as: UTF8.self)))
  }

  private func handle(_ message: ServerWebSocketMessage) {
    if case let .data(binary) = message {
      guard let envelopes = try? CloudRelayWire.decode(binary) else { return }
      for wire in envelopes {
        guard let header = try? JSONDecoder().decode(RelayHeader.self, from: wire.header)
        else { continue }
        let envelope = RelayEnvelope(
          machineId: header.machineId,
          frame: header.frame,
          payload: wire.payload
        )
        lock.withLock { relayed.append(envelope) }
        onRelay?(envelope)
      }
      return
    }
    guard case let .string(text) = message else { return }
    let data = Data(text.utf8)
    struct Probe: Decodable {
      var t: String
    }
    guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return }
    switch probe.t {
    case "hello":
      struct Hello: Decodable {
        struct Device: Decodable {
          var deviceId: String
          var kind: String
          var publicKey: String
        }

        var device: Device
        var resume: String?
      }
      var payload = WelcomePayload(connectionId: "conn-0", machines: machines)
      if let hello = try? JSONDecoder().decode(Hello.self, from: data) {
        lock.withLock {
          sawHello = true
          appPublicKey = hello.device.publicKey
          let resumed =
            issueResumeTokens && acceptResume && hello.resume != nil
            && hello.resume == issuedToken
          if !resumed {
            connectionCounter += 1
            currentConnectionId = "conn-\(connectionCounter)"
          }
          if issueResumeTokens {
            issuedToken = "resume-\(connectionCounter)-\(scriptedSockets.count)"
          }
          payload = WelcomePayload(
            connectionId: currentConnectionId,
            machines: machines,
            resume: issuedToken,
            resumed: resumed ? true : nil
          )
        }
      }
      let welcome = try! JSONEncoder().encode(payload)
      currentSocket.push(.string(String(decoding: welcome, as: UTF8.self)))
    case "ping":
      if respondsToPing {
        currentSocket.pushJSON(#"{"t":"pong"}"#)
      }
    default:
      break
    }
  }

  private struct WelcomePayload: Encodable {
    var t = "welcome"
    var `protocol` = 2
    var connectionId: String
    var machines: [CloudMachine]
    var resume: String?
    var resumed: Bool?
  }
}

/// The responder half of relay channels for tests: performs the machine-side
/// key agreement, tracks per-channel seqs both ways, and lets a script send
/// sealed frames back.
@Observable
final class ScriptedRelayMachine: @unchecked Sendable {
  let deviceId: String
  let secretKey: Data
  let publicKey: String
  private let lock = NSLock()
  private var channels: [String: Channel] = [:]

  @Observable

  final class Channel {
    let cipher: CloudChannelCipher
    var nextInboundSeq: UInt64 = 0
    var nextOutboundSeq: UInt64 = 0
    var openPayload: Data?
    var messages: [Data] = []
    var closeReason: CloudChannelCloseReason?
    /// The opener negotiated prefix-framed (compressible) payloads.
    var compressedFraming = false

    init(cipher: CloudChannelCipher) {
      self.cipher = cipher
    }
  }

  init(deviceId: String = "machine-1") {
    self.deviceId = deviceId
    let pair = CloudChannelCrypto.generateKeyPair()
    secretKey = pair.secretKey
    publicKey = pair.publicKey
  }

  var presence: CloudMachine {
    CloudMachine(
      deviceId: deviceId,
      name: "Scripted Machine",
      os: "macOS",
      publicKey: publicKey,
      online: true,
      lastSeenAt: "2026-01-01T00:00:00.000Z"
    )
  }

  func channel(_ id: String) -> Channel? {
    lock.withLock { channels[id] }
  }

  /// Handles one app→machine relay envelope, decrypting with the machine's
  /// keys. Returns the decrypted payload for open/data frames.
  @discardableResult
  func receive(
    _ frame: CloudRelayFrame,
    payload: Data,
    appPublicKey: String
  ) throws -> Data? {
    switch frame {
    case let .open(channelId, seq, ephemeralKey):
      let cipher = try CloudChannelCrypto.acceptChannel(
        responderSecretKey: secretKey,
        openerPublicKey: appPublicKey,
        ephemeralPublicKey: ephemeralKey
      )
      let channel = Channel(cipher: cipher)
      channel.nextInboundSeq = seq + 1
      channel.openPayload = try cipher.open(
        payload, channelId: channelId, direction: .openerToResponder, seq: seq
      )
      struct CompressProbe: Decodable { var compress: Bool? }
      if let openPayload = channel.openPayload,
        let probe = try? JSONDecoder().decode(CompressProbe.self, from: openPayload)
      {
        channel.compressedFraming = probe.compress == true
      }
      lock.withLock { channels[channelId] = channel }
      return channel.openPayload
    case let .data(channelId, seq):
      guard let channel = channel(channelId), channel.nextInboundSeq == seq else {
        throw CloudChannelCryptoError.openFailed
      }
      channel.nextInboundSeq += 1
      var plaintext = try channel.cipher.open(
        payload, channelId: channelId, direction: .openerToResponder, seq: seq
      )
      if channel.compressedFraming {
        guard plaintext.first == CloudDeflate.framingRaw else {
          throw CloudChannelCryptoError.openFailed
        }
        plaintext = Data(plaintext.dropFirst())
      }
      channel.messages.append(plaintext)
      return plaintext
    case let .credit(channelId, seq, _):
      guard let channel = channel(channelId), channel.nextInboundSeq == seq else {
        throw CloudChannelCryptoError.openFailed
      }
      channel.nextInboundSeq += 1
      return nil
    case let .close(channelId, seq, reason):
      guard let channel = channel(channelId), channel.nextInboundSeq == seq else {
        throw CloudChannelCryptoError.openFailed
      }
      channel.nextInboundSeq += 1
      channel.closeReason = reason
      return nil
    }
  }

  /// Seals a machine→app data frame (header + ciphertext payload). On
  /// channels that negotiated compressible framing the body is RAW-framed.
  func sealData(
    channelId: String,
    payload: Data
  ) throws -> (frame: CloudRelayFrame, payload: Data) {
    guard let channel = channel(channelId) else { throw CloudChannelCryptoError.openFailed }
    let body = channel.compressedFraming ? Data([CloudDeflate.framingRaw]) + payload : payload
    let seq = channel.nextOutboundSeq
    channel.nextOutboundSeq += 1
    let box = try channel.cipher.seal(
      body, channelId: channelId, direction: .responderToOpener, seq: seq
    )
    return (frame: .data(channelId: channelId, seq: seq), payload: box)
  }

  /// Seals a machine→app data frame whose body is DEFLATE-framed — only
  /// valid on channels that negotiated compressible framing.
  func sealDeflated(
    channelId: String,
    payload: Data
  ) throws -> (frame: CloudRelayFrame, payload: Data) {
    guard let channel = channel(channelId) else { throw CloudChannelCryptoError.openFailed }
    let body = try Data([CloudDeflate.framingDeflate]) + CloudDeflate.deflate(payload)
    let seq = channel.nextOutboundSeq
    channel.nextOutboundSeq += 1
    let box = try channel.cipher.seal(
      body, channelId: channelId, direction: .responderToOpener, seq: seq
    )
    return (frame: .data(channelId: channelId, seq: seq), payload: box)
  }

  func creditFrame(channelId: String, bytes: Int) -> CloudRelayFrame {
    guard let channel = channel(channelId) else {
      return .credit(channelId: channelId, seq: 0, bytes: bytes)
    }
    let seq = channel.nextOutboundSeq
    channel.nextOutboundSeq += 1
    return .credit(channelId: channelId, seq: seq, bytes: bytes)
  }

  func closeFrame(channelId: String, reason: CloudChannelCloseReason) -> CloudRelayFrame {
    guard let channel = channel(channelId) else {
      return .close(channelId: channelId, seq: 0, reason: reason)
    }
    let seq = channel.nextOutboundSeq
    channel.nextOutboundSeq += 1
    return .close(channelId: channelId, seq: seq, reason: reason)
  }
}

/// Waits for fixture state changes; the test runner owns the hang watchdog.
@MainActor
func waitUntil(_ condition: () -> Bool) async -> Bool {
  await awaitObserved(condition)
  return condition()
}
