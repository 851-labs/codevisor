import CodevisorTestSupport
import CoreGraphics
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCore
@testable import CodevisorCoreMac

@MainActor
final class SimulatorStreamHostWorld {
  static let udid = "8C2D33A1-7E5B-4F0A-9C3D-2B1E4F6A7D90"
  static let target = "simulator:\(udid)"
  static let viewerEndpoint = String(repeating: "b", count: 64)
  static let grant = ServerScreenSharingMediaGrant(
    endpointId: String(repeating: "a", count: 64), relayUrl: nil, directAddrs: ["10.0.0.2:4433"], token: "token")

  var isLoaded = true
  var booted: Set<String> = [SimulatorStreamHostWorld.udid]
  var lookupFailure: String?
  var screenSize: CGSize? = CGSize(width: 402, height: 874)
  var captureFails = false
  var offersV2 = true
  var hostKey: String? = String(repeating: "c", count: 64)
  var clock: TimeInterval = 100
  var screenGate: TestSignal?
  let screenAwaited = TestSignal()
  var devices: [SimulatorStreamHostDevice] = []
  var peers: [SimulatorStreamHostPeer] = []
  let workspace = UUID()
  let pane = UUID()
  let viewer = UUID()
  let hosting = ScreenSharingHostActivityLog()

  func host() -> SimulatorStreamHost {
    SimulatorStreamHost(
      dependencies: .init(
        isLoaded: { [unowned self] in isLoaded },
        isBooted: { [unowned self] udid in
          if let lookupFailure { throw SimulatorRuntime.Failure(lookupFailure) }
          return booted.contains(udid)
        },
        openDevice: { [unowned self] udid in
          let device = SimulatorStreamHostDevice(udid: udid, screenSize: screenSize, captureFails: captureFails)
          devices.append(device)
          return device
        },
        makePeer: { [unowned self] _, _, _ in
          let peer = SimulatorStreamHostPeer()
          peers.append(peer)
          return peer
        },
        offersV2: { [unowned self] in offersV2 },
        hostKey: { [unowned self] in hostKey },
        now: { [unowned self] in clock },
        sleep: { [weak self] _ in await self?.screenWait() }), activity: hosting.activity)
  }

  func request(
    _ operation: ServerScreenSharingRequest.Operation, viewer: UUID? = nil, target: String = target
  ) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: operation, workspaceId: workspace, paneId: pane, viewerId: viewer ?? self.viewer, displayId: target)
    if operation == .capabilities { request.app = .macBook }
    return request
  }

  func started(
    as app: ServerScreenSharingApp = .macBook, on host: SimulatorStreamHost, target: String = target
  ) async throws -> (start: ServerScreenSharingRequest, reply: ServerScreenSharingReply) {
    let start = try await start(as: app, on: host, target: target)
    return (start, await host.handle(start))
  }

  func following(
    _ started: (start: ServerScreenSharingRequest, reply: ServerScreenSharingReply),
    _ operation: ServerScreenSharingRequest.Operation
  ) -> ServerScreenSharingRequest {
    following(started.start, operation, session: started.reply.session)
  }

  func capabilities(as app: ServerScreenSharingApp, target: String = target) -> ServerScreenSharingRequest {
    var request = request(.capabilities, target: target)
    request.app = app
    return request
  }

  func start(
    as app: ServerScreenSharingApp, on host: SimulatorStreamHost, target: String = target
  ) async throws -> ServerScreenSharingRequest {
    var start = ServerScreenSharingRequest(
      operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID(), displayId: target)
    start.engine = "v2"
    start.media = .init(endpointId: app.key, relayUrl: nil, directAddrs: [])
    start.app = app
    start.intent = .attach
    let challenge = try #require(await host.handle(capabilities(as: app, target: target)).challenge)
    start.proof = try ServerScreenSharingProof(of: start, answering: challenge, signer: app.signer)
    return start
  }

  func following(
    _ start: ServerScreenSharingRequest, _ operation: ServerScreenSharingRequest.Operation, session: String?
  ) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: operation, workspaceId: UUID(), paneId: UUID(), viewerId: start.viewerId,
      displayId: start.displayId)
    request.session = session
    return request
  }

  private func screenWait() async {
    screenAwaited.signal()
    await screenGate?.wait()
  }
}

@MainActor
final class SimulatorStreamHostDevice: SimulatorStreamDevice {
  let udid: String
  var onChange: (() -> Void)?
  var state = ScreenSharingSimulatorState(orientation: .portrait)
  var screenSize: CGSize?
  private(set) var sinks: [any SimulatorFrameSink] = []
  private(set) var received: [ScreenSharingSimulatorMessage] = []
  private(set) var touchesReleased = 0
  private(set) var isClosed = false
  private let captureFails: Bool

  init(udid: String, screenSize: CGSize?, captureFails: Bool) {
    self.udid = udid
    self.screenSize = screenSize
    self.captureFails = captureFails
  }

  func startCapturing() throws {
    if captureFails { throw SimulatorRuntime.Failure("The simulator has no screen to show.") }
  }

  func show(to sink: any SimulatorFrameSink) { sinks.append(sink) }

  func hide(from sink: any SimulatorFrameSink) { sinks.removeAll { $0 === sink } }

  func receive(_ message: ScreenSharingSimulatorMessage) { received.append(message) }

  func releaseTouches() { touchesReleased += 1 }

  func close() { isClosed = true }
}

@MainActor
final class SimulatorStreamHostPeer: SimulatorStreamPeer {
  let viewer: ScreenSharingLocalChannel<ScreenSharingSimulatorMessage>
  private let hostSide: ScreenSharingLocalChannel<ScreenSharingSimulatorMessage>
  var onConnectionChanged: ((String) -> Void)?
  var startFails = false
  private(set) var isClosed = false

  init() {
    (hostSide, viewer) = ScreenSharingLocalChannel<ScreenSharingSimulatorMessage>.pair(hop: { work in
      MainActor.assumeIsolated { work() }
    })
  }

  var channel: any ScreenSharingMessageChannel<ScreenSharingSimulatorMessage> { hostSide }

  func start(failed: @escaping @MainActor (String) -> Void) async throws -> ServerScreenSharingMediaGrant {
    if startFails { throw SimulatorRuntime.Failure("The viewer's address is unreachable in this test.") }
    return SimulatorStreamHostWorld.grant
  }

  func prepare(size: CGSize) {}

  nonisolated func push(_ frame: ScreenSharingVideoFrame) {}

  func close() { isClosed = true }
}
