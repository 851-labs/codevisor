import CodevisorClient
import CodevisorCore
import Foundation
import ScreenSharingConnection
import ScreenSharingV2

@MainActor
struct ScreenSharingDesktopSources {
  var signer: () throws -> ScreenSharingStartSigner
  var channel: (_ machineId: String) -> any ScreenSharingHostChannel
  var connector: ScreenSharingV2Connector
  var machineName: (_ machineId: String) -> String?
  var isReady: (_ machineId: String) -> Bool
  var isLive: (_ workspaceId: UUID) -> Bool
  var liveWorkspaces: (_ machineId: String) -> [UUID]
  var workspacesRevision: () -> UInt64

  init(
    signer: @escaping () throws -> ScreenSharingStartSigner,
    channel: @escaping (_ machineId: String) -> any ScreenSharingHostChannel, connector: ScreenSharingV2Connector,
    machineName: @escaping (_ machineId: String) -> String?, isReady: @escaping (_ machineId: String) -> Bool,
    isLive: @escaping (_ workspaceId: UUID) -> Bool, liveWorkspaces: @escaping (_ machineId: String) -> [UUID],
    workspacesRevision: @escaping () -> UInt64
  ) {
    self.signer = signer
    self.channel = channel
    self.connector = connector
    self.machineName = machineName
    self.isReady = isReady
    self.isLive = isLive
    self.liveWorkspaces = liveWorkspaces
    self.workspacesRevision = workspacesRevision
  }

  init(environment: AppEnvironment) {
    let (machines, workspaces, navigation) = (environment.machines, environment.workspaces, environment.navigationStore)
    self.init(
      signer: { [weak environment] in
        guard let environment else { throw CancellationError() }

        return try environment.screenSharingSigner()
      },
      channel: { ScreenSharingServerChannel(client: machines.client(for: $0)) },
      connector: Self.liveConnector,
      machineName: { machines.machine(for: $0)?.name },
      isReady: { machines.availability(for: $0) == .ready },
      isLive: { Self.isLive(workspaces.workspace(id: $0)) },
      liveWorkspaces: { machineId in
        workspaces.loadAll().filter { $0.serverId == machineId && Self.isLive($0) }.map(\.id)
      },
      workspacesRevision: { navigation.revision })
  }

  private static var liveConnector: ScreenSharingV2Connector {
    var connector = ScreenSharingV2Connector.live()
    connector.chroma = { ScreenSharingPaneModel.requestedChroma }
    return connector
  }

  private static func isLive(_ workspace: Workspace?) -> Bool {
    guard let workspace else { return false }

    return workspace.isServerSynced && !workspace.isArchived
  }
}
