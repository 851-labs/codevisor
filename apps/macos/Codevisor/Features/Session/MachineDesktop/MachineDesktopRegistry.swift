import CodevisorClient
import CodevisorCore
import CodevisorCoreMac
import Foundation

@MainActor
final class MachineDesktopRegistry {
  static let shared = MachineDesktopRegistry()

  private var sessions: [UUID: MachineDesktopSession] = [:]

  func session(for workspace: Workspace, project: Project, environment: AppEnvironment) -> MachineDesktopSession? {
    if let existing = sessions[workspace.id] { return existing }
    guard environment.machines.statusByMachineId[workspace.serverId]?.supportsScreenSharing == true,
      let machine = environment.machines.machine(for: workspace.serverId)
    else { return nil }

    let session = makeSession(workspace: workspace, project: project, machine: machine, environment: environment)
    sessions[workspace.id] = session
    return session
  }

  private func makeSession(
    workspace: Workspace, project: Project, machine: CodevisorMachine, environment: AppEnvironment
  ) -> MachineDesktopSession {
    let client = environment.machines.client(for: workspace.serverId)
    let paneId = MachineDesktopSession.paneId(forWorkspace: workspace.id)
    let descriptor = PaneDescriptorState(
      id: paneId, kind: .screenSharing, name: "Desktop", terminalKey: paneId.uuidString,
      screenSharing: ScreenSharingPanePreferences())
    let context = PaneContext(
      paneId: paneId, sessionId: nil, terminalKey: descriptor.terminalKey, machine: machine, session: nil,
      project: project, workspaceRootDirectory: workspace.rootDirectory, workspaceId: workspace.id, client: client,
      openTunnelMedia: Self.tunnelMedia(serverId: workspace.serverId, machines: environment.machines))
    let pane = ScreenSharingPane(context: context, descriptor: descriptor)
    return MachineDesktopSession(pane: pane, workspaceId: workspace.id, client: client)
  }

  private static func tunnelMedia(
    serverId: String, machines: MachineController
  ) -> ScreenSharingViewerBackend.TunnelMediaProvider {
    { [weak machines] in
      guard let route = await machines?.tunnelMediaRoute(forMachineId: serverId) else { return nil }
      return ScreenSharingTunnelMedia(
        endpointId: route.endpointId, flowId: Int(route.flowId), localPort: route.localPort,
        close: { route.close() })
    }
  }
}
