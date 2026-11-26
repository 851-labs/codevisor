import CodevisorClient
import CodevisorCore
import Foundation
import ScreenSharingConnection
import ScreenSharingV2

@MainActor
struct ScreenSharingDesktopSources {
  typealias OpenVNCSocket =
    @Sendable (_ machineId: String, _ displayId: String) async throws -> any ServerWebSocketConnecting

  var signer: () throws -> ScreenSharingStartSigner
  var channel: (_ machineId: String) -> any ScreenSharingHostChannel
  var connector: ScreenSharingV2Connector
  var machineName: (_ machineId: String) -> String?
  var isReady: (_ machineId: String) -> Bool
  var userAsked: (_ machineId: String) -> Void = { _ in }
  var openVNCSocket: OpenVNCSocket?

  init(
    signer: @escaping () throws -> ScreenSharingStartSigner,
    channel: @escaping (_ machineId: String) -> any ScreenSharingHostChannel, connector: ScreenSharingV2Connector,
    machineName: @escaping (_ machineId: String) -> String?, isReady: @escaping (_ machineId: String) -> Bool
  ) {
    self.signer = signer
    self.channel = channel
    self.connector = connector
    self.machineName = machineName
    self.isReady = isReady
  }

  init(environment: AppEnvironment) {
    let machines = environment.machines
    self.init(
      signer: { [weak environment] in
        guard let environment else { throw CancellationError() }

        return try environment.screenSharingSigner()
      },
      channel: { ScreenSharingServerChannel(client: machines.client(for: $0)) },
      connector: Self.liveConnector,
      machineName: { machines.machine(for: $0)?.name },
      isReady: { machines.availability(for: $0) == .ready })
    userAsked = { machines.redialTunnel(for: $0) }
    openVNCSocket = { machineId, displayId in
      try await machines.client(for: machineId).screenSharingVNCSocket(displayId: displayId)
    }
  }

  private static var liveConnector: ScreenSharingV2Connector {
    var connector = ScreenSharingV2Connector.live()
    connector.chroma = { ScreenSharingPaneModel.requestedChroma }
    return connector
  }
}
