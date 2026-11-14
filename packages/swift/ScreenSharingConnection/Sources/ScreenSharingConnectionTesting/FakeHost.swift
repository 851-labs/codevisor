import CodevisorClient
import CodevisorTestSupport
import Foundation
import Observation
import ScreenSharingConnection

@MainActor
@Observable
public final class FakeHost: ScreenSharingHostChannel {
  public typealias Operation = ServerScreenSharingRequest.Operation

  public enum Answer {
    case reply(status: String, message: String? = nil, reason: String? = nil, holderName: String? = nil)
    case failure(any Error)
  }

  public nonisolated static let display = ServerScreenSharingDisplay(
    id: "0A000000-0000-4000-8000-000000000001", name: "Built-in Display", width: 1920, height: 1080)
  public nonisolated static let second = ServerScreenSharingDisplay(
    id: "0A000000-0000-4000-8000-000000000002", name: "Studio Display", width: 2560, height: 1440)
  public nonisolated static let grant = ServerScreenSharingMediaGrant(
    endpointId: String(repeating: "b", count: 64), relayUrl: nil, directAddrs: [], token: "grant token")
  public nonisolated static let unreachable: any Error = URLError(.cannotConnectToHost)
  public nonisolated static let interrupted: any Error = URLError(.networkConnectionLost)
  public nonisolated static let gatewayTimedOut: any Error = CodevisorServerClientError.httpStatus(
    504, #"{"error":"The host Mac didn't answer in time; its screen capture may be stuck. Retry in a minute."}"#)
  public nonisolated static let paneGone: any Error = CodevisorServerClientError.httpStatus(
    404, #"{"error":"Screen Sharing pane is no longer available"}"#)

  public var abilities: [String]
  public var mintsChallenges = true
  public var challengeHostKey = FakeHost.grant.endpointId
  public var forgedNonce: String?
  public var provider: String?
  public var displays = [FakeHost.display]
  public var isReconnecting = false
  public var onStart: (() -> Void)?
  public private(set) var requests: [ServerScreenSharingRequest] = []
  public private(set) var completed: [Operation: Int] = [:]
  public private(set) var registeredPanes: [ScreenSharingLegacyIdentity] = []
  @ObservationIgnored private var queued: [Operation: [Answer]] = [:]
  @ObservationIgnored private var standing: [Operation: Answer] = [:]
  @ObservationIgnored private var gates: [Operation: TestSignal] = [:]
  @ObservationIgnored private var liveNonces: Set<String> = []
  @ObservationIgnored private var minted = 0

  public init(abilities: [String] = [ServerScreenSharingReply.appSessions]) {
    self.abilities = abilities
  }

  public static func old() -> FakeHost { FakeHost(abilities: []) }

  public func requests(_ operation: Operation) -> [ServerScreenSharingRequest] {
    requests.filter { $0.operation == operation }
  }

  public var starts: [ServerScreenSharingRequest] { requests(.start) }

  public var stops: [ServerScreenSharingRequest] { requests(.stop) }

  public func completed(_ operation: Operation) -> Int { completed[operation, default: 0] }

  public func releaseEverything() {
    for gate in gates.values { gate.signal() }
    gates = [:]
  }

  public func answerNext(_ operation: Operation, _ answers: Answer...) {
    queued[operation, default: []] += answers
  }

  public func answerEvery(_ operation: Operation, _ answer: Answer?) {
    standing[operation] = answer
  }

  public func hold(_ operation: Operation) {
    gates[operation] = TestSignal()
  }

  public func release(_ operation: Operation) {
    gates.removeValue(forKey: operation)?.signal()
  }

  public func send(_ request: ServerScreenSharingRequest) async throws -> ServerScreenSharingReply {
    let operation = request.operation
    requests.append(request)
    if operation == .start, let onStart {
      self.onStart = nil
      onStart()
    }
    await gates[operation]?.wait()
    completed[operation, default: 0] += 1
    let scripted = queued[operation]?.isEmpty == false ? queued[operation]?.removeFirst() : standing[operation]
    switch scripted {
    case .failure(let error):
      throw error
    case .reply(let status, let message, let reason, let holderName):
      var reply = ServerScreenSharingReply(status: status, message: message)
      reply.abilities = abilities
      reply.reason = reason.map(ServerScreenSharingReason.init(rawValue:))
      reply.holderName = holderName
      if reply.reason == .proofRejected { reply.challenge = mintChallenge() }
      if status == "connecting" { reply.media = Self.grant }
      if status == "connecting", request.app != nil { reply.session = mintSession() }
      return reply
    case nil:
      return healthyReply(to: request)
    }
  }

  public func registerDesktopPane(_ identity: ScreenSharingLegacyIdentity) async throws {
    registeredPanes.append(identity)
  }

  public static func token(_ number: Int) -> String {
    String(repeating: "0", count: 60) + String(format: "%04x", number)
  }

  private var verifiesApps: Bool { mintsChallenges && abilities.contains(ServerScreenSharingReply.appSessions) }

  private func mintChallenge() -> ServerScreenSharingChallenge {
    minted += 1
    let nonce = Self.token(minted)
    liveNonces.insert(nonce)
    return ServerScreenSharingChallenge(hostKey: challengeHostKey, nonce: forgedNonce ?? nonce)
  }

  private func mintSession() -> String {
    minted += 1
    return Self.token(minted)
  }

  private func acceptsTheProof(of request: ServerScreenSharingRequest) -> Bool {
    guard verifiesApps, request.app != nil else { return true }
    guard let nonce = request.proof?.nonce else { return false }

    return liveNonces.remove(nonce) != nil
  }

  private func healthyReply(to request: ServerScreenSharingRequest) -> ServerScreenSharingReply {
    var reply: ServerScreenSharingReply
    switch request.operation {
    case .capabilities:
      reply = ServerScreenSharingReply(status: "available", displays: displays, provider: provider)
      reply.engines = ["v2"]
      if verifiesApps, request.app != nil { reply.challenge = mintChallenge() }
    case .start, .restart:
      guard acceptsTheProof(of: request) else { return proofRejected() }

      reply = sharing(status: "connecting", for: request)
      reply.media = Self.grant
      if verifiesApps, request.app != nil { reply.session = mintSession() }
    case .heartbeat:
      reply = sharing(status: "viewing", for: request)
    case .stop, .setScale:
      reply = ServerScreenSharingReply(status: "stopped")
    }
    reply.abilities = abilities
    return reply
  }

  private func proofRejected() -> ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(status: "failed", message: "The request couldn't be verified.")
    reply.abilities = abilities
    reply.reason = .proofRejected
    reply.challenge = mintChallenge()
    return reply
  }

  private func sharing(status: String, for request: ServerScreenSharingRequest) -> ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(status: status)
    guard verifiesApps, request.app != nil || request.session != nil else { return reply }

    reply.displays = displays
    reply.display = displays.first { $0.id == request.displayId } ?? displays.first
    return reply
  }
}
