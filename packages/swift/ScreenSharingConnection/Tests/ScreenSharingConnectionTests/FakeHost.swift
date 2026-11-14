import CodevisorClient
import CodevisorTestSupport
import Foundation
import Observation
import ScreenSharingConnection

@MainActor
@Observable
final class FakeHost: ScreenSharingHostChannel {
  typealias Operation = ServerScreenSharingRequest.Operation

  enum Answer {
    case reply(status: String, message: String? = nil, reason: String? = nil, holderName: String? = nil)
    case failure(any Error)
  }

  nonisolated static let display = ServerScreenSharingDisplay(
    id: "0A000000-0000-4000-8000-000000000001", name: "Built-in Display", width: 1920, height: 1080)
  nonisolated static let second = ServerScreenSharingDisplay(
    id: "0A000000-0000-4000-8000-000000000002", name: "Studio Display", width: 2560, height: 1440)
  nonisolated static let grant = ServerScreenSharingMediaGrant(
    endpointId: String(repeating: "b", count: 64), relayUrl: nil, directAddrs: [], token: "grant token")
  nonisolated static let unreachable: any Error = URLError(.cannotConnectToHost)
  nonisolated static let interrupted: any Error = URLError(.networkConnectionLost)
  nonisolated static let gatewayTimedOut: any Error = CodevisorServerClientError.httpStatus(
    504, #"{"error":"The host Mac didn't answer in time; its screen capture may be stuck. Retry in a minute."}"#)
  nonisolated static let paneGone: any Error = CodevisorServerClientError.httpStatus(
    404, #"{"error":"Screen Sharing pane is no longer available"}"#)

  var abilities: [String]
  var mintsChallenges = true
  var challengeHostKey = FakeHost.grant.endpointId
  var provider: String?
  var displays = [FakeHost.display]
  var isReconnecting = false
  var onStart: (() -> Void)?
  private(set) var requests: [ScreenSharingHostRequest] = []
  private(set) var completed: [Operation: Int] = [:]
  private(set) var registeredPanes: [ScreenSharingLegacyIdentity] = []
  @ObservationIgnored private var queued: [Operation: [Answer]] = [:]
  @ObservationIgnored private var standing: [Operation: Answer] = [:]
  @ObservationIgnored private var gates: [Operation: TestSignal] = [:]
  @ObservationIgnored private var liveNonces: Set<String> = []
  @ObservationIgnored private var minted = 0

  init(abilities: [String] = [ScreenSharingHostReply.appSessions]) {
    self.abilities = abilities
  }

  static func old() -> FakeHost { FakeHost(abilities: []) }

  func requests(_ operation: Operation) -> [ScreenSharingHostRequest] {
    requests.filter { $0.base.operation == operation }
  }

  var starts: [ScreenSharingHostRequest] { requests(.start) }

  var stops: [ScreenSharingHostRequest] { requests(.stop) }

  func completed(_ operation: Operation) -> Int { completed[operation, default: 0] }

  func releaseEverything() {
    for gate in gates.values { gate.signal() }
    gates = [:]
  }

  func answerNext(_ operation: Operation, _ answers: Answer...) {
    queued[operation, default: []] += answers
  }

  func answerEvery(_ operation: Operation, _ answer: Answer?) {
    standing[operation] = answer
  }

  func hold(_ operation: Operation) {
    gates[operation] = TestSignal()
  }

  func release(_ operation: Operation) {
    gates.removeValue(forKey: operation)?.signal()
  }

  func send(_ request: ScreenSharingHostRequest) async throws -> ScreenSharingHostReply {
    let operation = request.base.operation
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
      var base = ServerScreenSharingReply(status: status, message: message)
      if status == "connecting" { base.media = Self.grant }
      var reply = ScreenSharingHostReply(base, abilities: abilities, reason: reason, holderName: holderName)
      if reason == ScreenSharingHostReply.proofRejected { reply.challenge = mintChallenge() }
      if status == "connecting", request.app != nil { reply.session = mintSession() }
      return reply
    case nil:
      return healthyReply(to: request)
    }
  }

  static func token(_ number: Int) -> String {
    String(repeating: "0", count: 60) + String(format: "%04x", number)
  }

  private var verifiesApps: Bool { mintsChallenges && abilities.contains(ScreenSharingHostReply.appSessions) }

  private func mintChallenge() -> ScreenSharingChallenge {
    minted += 1
    let nonce = Self.token(minted)
    liveNonces.insert(nonce)
    return ScreenSharingChallenge(hostKey: challengeHostKey, nonce: nonce)
  }

  private func mintSession() -> String {
    minted += 1
    return Self.token(minted)
  }

  private func acceptsTheProof(of request: ScreenSharingHostRequest) -> Bool {
    guard verifiesApps, request.app != nil else { return true }
    guard let nonce = request.proof?.nonce else { return false }

    return liveNonces.remove(nonce) != nil
  }

  func registerDesktopPane(_ identity: ScreenSharingLegacyIdentity) async throws {
    registeredPanes.append(identity)
  }

  private func healthyReply(to request: ScreenSharingHostRequest) -> ScreenSharingHostReply {
    switch request.base.operation {
    case .capabilities:
      var base = ServerScreenSharingReply(status: "available", displays: displays, provider: provider)
      base.engines = ["v2"]
      var reply = ScreenSharingHostReply(base, abilities: abilities)
      if verifiesApps, request.app != nil { reply.challenge = mintChallenge() }
      return reply
    case .start, .restart:
      guard acceptsTheProof(of: request) else {
        var rejected = ScreenSharingHostReply(
          ServerScreenSharingReply(status: "failed", message: "The request couldn't be verified."),
          abilities: abilities, reason: ScreenSharingHostReply.proofRejected)
        rejected.challenge = mintChallenge()
        return rejected
      }

      var base = ServerScreenSharingReply(status: "connecting")
      base.media = Self.grant
      var reply = sharing(base, for: request)
      if verifiesApps, request.app != nil { reply.session = mintSession() }
      return reply
    case .heartbeat:
      return sharing(ServerScreenSharingReply(status: "viewing"), for: request)
    case .stop, .setScale:
      return ScreenSharingHostReply(ServerScreenSharingReply(status: "stopped"), abilities: abilities)
    }
  }

  private func sharing(
    _ base: ServerScreenSharingReply, for request: ScreenSharingHostRequest
  ) -> ScreenSharingHostReply {
    guard verifiesApps, request.app != nil || request.session != nil else {
      return ScreenSharingHostReply(base, abilities: abilities)
    }

    var base = base
    base.displays = displays
    let shared = displays.first { $0.id == request.base.displayId } ?? displays.first
    return ScreenSharingHostReply(base, abilities: abilities, display: shared)
  }
}
