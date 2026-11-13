import CodevisorClient
import CodevisorTestSupport
import ComposableArchitecture
import CustomDump
import Foundation
import ScreenSharingV2
import Testing
@testable import CodevisorCoreMac

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingDisplaySwapTests {
  private let host = DisplaySwappingHost()
  private let machineId = UUID().uuidString

  @Test func aWindowOpenedAfterTheHostSwappedItsDisplayJoinsThePreviewsConnection() async {
    let preview = surface(.watcher)
    let window = surface(.window)
    preview.send(.paneAppeared)
    await awaitObserved { preview.mirror != nil }

    window.send(.paneAppeared)

    await awaitObserved { [.viewing, .failed].contains(window.phase) }
    #expect(window.phase == .viewing && window.message == nil)
    #expect(window.endpoint != nil && window.endpoint == preview.mirror)
    expectNoDifference(window.displays.map(\.id), [DisplaySwappingHost.virtual.id])
    let starts = await host.starts
    expectNoDifference(starts, [DisplaySwappingHost.standIn.id])
    await window.send(.paneClosed).finish()
    await preview.send(.paneClosed).finish()
    await host.stopped.wait()
  }

  private func surface(_ role: ScreenSharingViewerRole) -> StoreOf<ScreenSharingViewer> {
    let clock = TestClock()
    let connector = ScreenSharingV2Connector(
      address: { ScreenSharingViewerFixtures.viewerMedia }, connect: { _ in FakeMediaSession() })
    let backend = ScreenSharingViewerBackend.native(
      client: CodevisorServerClient(config: .init(requestTransport: host)), workspaceId: UUID(), paneId: UUID(),
      machineId: machineId, role: role, v2: connector, sleep: { try await clock.sleep(for: $0) },
      now: { clock.now },
      makeSurface: { session in
        let surface = FakeSurface()
        (session as? FakeMediaSession)?.surface = surface
        return surface
      })
    return Store(initialState: ScreenSharingViewer.State()) {
      ScreenSharingViewer()
    } withDependencies: {
      $0[ScreenSharingViewerBackend.self] = backend
      $0[ScreenSharingEndpointClient.self] = FakeEndpointClient().value
      $0.continuousClock = Clocks.TestClock<Duration>()
    }
  }
}

private actor DisplaySwappingHost: ServerRequestTransport {
  static let standIn = ServerScreenSharingDisplay(id: "stand-in", name: "Display", width: 1920, height: 1080)
  static let virtual = ServerScreenSharingDisplay(
    id: "virtual", name: "Codevisor Screen Sharing", width: 3840, height: 2160)
  static let busy = "This Mac is already sharing with another viewer."

  nonisolated let stopped = TestSignal()
  private(set) var starts: [String?] = []
  private var sharingWith: UUID?

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let payload = try JSONDecoder().decode(ServerScreenSharingRequest.self, from: request.httpBody ?? Data())
    return (
      try JSONEncoder().encode(reply(to: payload)),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }

  private var displays: [ServerScreenSharingDisplay] { [sharingWith == nil ? Self.standIn : Self.virtual] }

  private func reply(to request: ServerScreenSharingRequest) -> ServerScreenSharingReply {
    switch request.operation {
    case .capabilities:
      var reply = ServerScreenSharingReply(status: sharingWith == nil ? "available" : "busy", displays: displays)
      reply.engines = ["v2"]
      return reply
    case .start, .restart: return start(request)
    case .heartbeat: return .init(status: "viewing")
    case .setScale: return .init(status: "unsupported")
    case .stop:
      if sharingWith == request.paneId { sharingWith = nil }
      stopped.signal()
      return .init(status: "stopped")
    }
  }

  private func start(_ request: ServerScreenSharingRequest) -> ServerScreenSharingReply {
    starts.append(request.displayId)
    guard sharingWith == nil || sharingWith == request.paneId else { return .init(status: "busy", message: Self.busy) }
    guard displays.contains(where: { $0.id == request.displayId }) else {
      return .init(status: "unavailable", message: "The selected display is no longer available.")
    }
    sharingWith = request.paneId
    var reply = ServerScreenSharingReply(status: "connecting")
    reply.media = ScreenSharingViewerFixtures.mediaGrant
    return reply
  }
}
