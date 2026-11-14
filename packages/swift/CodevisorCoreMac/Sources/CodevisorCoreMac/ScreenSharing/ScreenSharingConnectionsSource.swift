import CodevisorClient
import CodevisorCore
import Foundation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingV2

@MainActor
public struct ScreenSharingConnectionsSource {
  public typealias OpenVNC =
    @Sendable (_ machineId: String, _ displayId: String) async throws -> (
      client: RFBClient, outcome: RFBHandshake.Outcome
    )

  public var machineIds: @MainActor () -> Set<String>
  public var isReady: @MainActor (_ machineId: String) -> Bool
  public var channel: @MainActor (_ machineId: String) -> any ScreenSharingHostChannel
  public var openVNC: OpenVNC
  public var workspaces: @MainActor () -> [Workspace]
  public var signer: @MainActor () throws -> ScreenSharingStartSigner
  public var appName: @MainActor () -> String
  public var connector: @MainActor () -> ScreenSharingV2Connector
  public var makeSurface: @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface

  public init(
    machineIds: @escaping @MainActor () -> Set<String>,
    isReady: @escaping @MainActor (_ machineId: String) -> Bool,
    channel: @escaping @MainActor (_ machineId: String) -> any ScreenSharingHostChannel,
    openVNC: @escaping OpenVNC,
    workspaces: @escaping @MainActor () -> [Workspace],
    signer: @escaping @MainActor () throws -> ScreenSharingStartSigner,
    connector: @escaping @MainActor () -> ScreenSharingV2Connector,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface = {
      try ScreenSharingVideoSurface(mailbox: $0.frames, metrics: $0.metrics)
    },
    appName: @escaping @MainActor () -> String = { ScreenSharingAppName.current }
  ) {
    self.machineIds = machineIds
    self.isReady = isReady
    self.channel = channel
    self.openVNC = openVNC
    self.workspaces = workspaces
    self.signer = signer
    self.appName = appName
    self.connector = connector
    self.makeSurface = makeSurface
  }

  public static func live(_ environment: AppEnvironment) -> Self {
    let machines = environment.machines
    return Self(
      machineIds: { machines.allMachineIds },
      isReady: { machines.availability(for: $0) == .ready },
      channel: { ScreenSharingServerChannel(client: machines.client(for: $0)) },
      openVNC: { machineId, displayId in
        let socket = try await machines.client(for: machineId).screenSharingVNCSocket(displayId: displayId)
        return try await VNCConnection.open(transport: RFBWebSocketTransport(socket: socket), password: nil)
      },
      workspaces: { environment.workspaces.loadAll() },
      signer: { try environment.screenSharingSigner() },
      connector: { ScreenSharingViewerMedia.connector })
  }
}
