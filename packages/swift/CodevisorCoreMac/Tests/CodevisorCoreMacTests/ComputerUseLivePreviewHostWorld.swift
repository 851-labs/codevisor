import CodevisorTestSupport
import CoreGraphics
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCore
@testable import CodevisorCoreMac

@MainActor
final class ComputerUseLivePreviewHostWorld {
  var access = true
  var activityState: ComputerUseLivePreview.State?
  var windowVisibility = ComputerUseWindowVisibility.visible
  var clock: TimeInterval = 100
  var peerGate: TestSignal?
  let peerRequested = TestSignal()
  var peers: [ComputerUseLivePreviewHostPeer] = []
  var requestedMedia: [ScreenSharingStreamMedia] = []
  var offersV2 = false
  var hostKey: String? = String(repeating: "c", count: 64)
  var attached: [(sessionID: String, sink: any ComputerUseFrameSink, token: UUID)] = []
  var detached: [UUID] = []
  let workspace = UUID()
  let pane = UUID()
  let viewer = UUID()
  let hosting = ScreenSharingHostActivityLog()

  func request(_ operation: ServerScreenSharingRequest.Operation, viewer: UUID? = nil) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: operation, workspaceId: workspace, paneId: pane, viewerId: viewer ?? self.viewer,
      displayId: ComputerUseLivePreviewHostTests.target)
    if operation == .capabilities { request.app = .macBook }
    return request
  }

  func started(
    as app: ServerScreenSharingApp = .macBook, on host: ComputerUseLivePreviewHost
  ) async throws -> (start: ServerScreenSharingRequest, reply: ServerScreenSharingReply) {
    let start = try await start(as: app, on: host)
    return (start, await host.handle(start))
  }

  func following(
    _ started: (start: ServerScreenSharingRequest, reply: ServerScreenSharingReply),
    _ operation: ServerScreenSharingRequest.Operation
  ) -> ServerScreenSharingRequest {
    following(started.start, operation, session: started.reply.session)
  }

  func capabilities(as app: ServerScreenSharingApp) -> ServerScreenSharingRequest {
    var request = request(.capabilities)
    request.app = app
    return request
  }

  func start(
    as app: ServerScreenSharingApp, on host: ComputerUseLivePreviewHost,
    target: String = ComputerUseLivePreviewHostTests.target
  ) async throws -> ServerScreenSharingRequest {
    var start = ServerScreenSharingRequest(
      operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID(), displayId: target)
    start.engine = "v2"
    start.media = .init(endpointId: app.key, relayUrl: nil, directAddrs: [])
    start.app = app
    start.intent = .attach
    let challenge = try #require(await host.handle(capabilities(as: app)).challenge)
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

  func host() -> ComputerUseLivePreviewHost {
    ComputerUseLivePreviewHost(
      dependencies: .init(
        captureAccess: { [unowned self] in access },
        activity: { [unowned self] id in
          guard let state = activityState, id == ComputerUseLivePreviewHostTests.session else { return nil }
          return .init(
            sessionID: id, bridgeSessionID: "BRIDGE-ID", appName: "TextEdit", pid: 42, windowID: 7,
            windowFrame: CGRect(x: 0, y: 0, width: 600, height: 400), colorIndex: 0, cursor: nil,
            state: state, windowVisibility: windowVisibility)
        },
        streamSize: { _ in CGSize(width: 960, height: 640) },
        attach: { [unowned self] id, sink in
          let token = UUID()
          attached.append((id, sink, token))
          return token
        },
        detach: { [unowned self] _, token in detached.append(token) },
        makePeer: { [unowned self] _, media in
          requestedMedia.append(media)
          peerRequested.signal()
          if let peerGate { await peerGate.wait() }
          let peer = ComputerUseLivePreviewHostPeer()
          peers.append(peer)
          return peer
        },
        offersV2: { [unowned self] in offersV2 },
        hostKey: { [unowned self] in hostKey },
        now: { [unowned self] in clock }
      ), activity: hosting.activity)
  }
}

@MainActor
final class ComputerUseLivePreviewHostPeer: ComputerUseStreamPeer {
  var onConnectionChanged: ((String) -> Void)?
  let sink: any ComputerUseFrameSink = RecordingSink()
  var closed = false

  func start(failed: @escaping @MainActor (String) -> Void) async throws -> ServerScreenSharingMediaGrant {
    ComputerUseLivePreviewHostTests.grant
  }
  func close() { closed = true }
}
