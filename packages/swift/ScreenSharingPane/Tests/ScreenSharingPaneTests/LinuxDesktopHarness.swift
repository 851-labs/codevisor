import CodevisorClient
import CodevisorTestSupport
import Foundation
import Observation
import ScreenSharing
import ScreenSharingConnectionTesting
import ScreenSharingTesting

@testable import ScreenSharingPane

@MainActor
final class LinuxDesktopHarness {
  static let screen = RFBRectangle(x: 0, y: 0, width: 64, height: 48)
  static let display = ServerScreenSharingDisplay(id: "vnc:desktop", name: "Desktop", width: 64, height: 48)

  @Observable
  final class Log {
    var desktopReceived: [RFBClientMessage] = []
    var relayReceived: [String] = []
    var sockets: [LinuxDesktopRelaySocket] = []
    var refusals = 0
  }

  let desktops = DesktopsHarness()
  let server: RFBLoopbackServer
  let log = Log()
  var relayRefuses = false
  private var feeds: [Task<Void, Never>] = []

  init(controlLease: Bool = false) async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.securityTypes = [RFBSecurityType.none.rawValue]
    server = try await RFBLoopbackServer(configuration: configuration)
    desktops.host.provider = "vnc"
    desktops.host.controlLease = controlLease
    desktops.host.displays = [Self.display]
    record(desktopMessagesInto: log)
    desktops.openVNCSocket = { [weak self] _, displayId in
      guard let socket = try await self?.openSocket(displayId: displayId) else { throw CancellationError() }

      return socket
    }
  }

  var input: [RFBClientMessage] {
    log.desktopReceived.filter {
      switch $0 {
      case .pointerEvent, .keyEvent: true
      default: false
      }
    }
  }

  var advertisedEncodings: [Int32]? {
    log.desktopReceived.lazy.compactMap {
      guard case .setEncodings(let encodings) = $0 else { return nil }

      return encodings
    }.first
  }

  func goLive() async -> ScreenSharingPaneModel? {
    let model = desktops.model()
    desktops.show(model)
    await paintUntilLive(model, socketCount: 1)
    return model
  }

  func paintUntilLive(_ model: ScreenSharingPaneModel?, socketCount: Int) async {
    await awaitObserved { log.sockets.count == socketCount && model?.session != nil }
    server.enqueue([.raw(Self.screen)])
    await awaitObserved { model?.isViewing == true }
  }

  func grantControl() {
    log.sockets.last?.sendToViewer(#"{"type":"granted"}"#)
  }

  func revokeControl(by name: String) {
    log.sockets.last?.sendToViewer(#"{"type":"revoked","by":"\#(name)"}"#)
  }

  func stop() {
    feeds.forEach { $0.cancel() }
    server.stop()
  }

  private func openSocket(displayId: String) async throws -> LinuxDesktopRelaySocket {
    guard !relayRefuses, displayId == Self.display.id else {
      log.refusals += 1
      throw CodevisorServerClientError.httpStatus(501, "This machine has no VNC display.")
    }

    let (texts, continuation) = AsyncStream<String>.makeStream()
    let socket = LinuxDesktopRelaySocket(
      desktop: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port)
    ) { continuation.yield($0) }
    feeds.append(Task { [log] in for await text in texts { log.relayReceived.append(text) } })
    log.sockets.append(socket)
    return socket
  }

  private func record(desktopMessagesInto log: Log) {
    let (messages, continuation) = AsyncStream<RFBClientMessage>.makeStream()
    server.onClientMessage = { continuation.yield($0) }
    feeds.append(Task { for await message in messages { log.desktopReceived.append(message) } })
  }
}
