import CodevisorCore
import SwiftUI

/// Each mounted root gets its own id. Every machine sees only the context
/// belonging to it; closing the window cancels all of its control channels.
public struct ClientControlModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.scenePhase) private var scenePhase
  @State private var clientId = UUID()
  let name: String
  let platform: String
  let isActive: Bool
  let context: @MainActor (String) -> NativeClientContext
  let navigate: @MainActor (String, ClientNavigationRequest) async throws -> Void

  public init(
    name: String,
    platform: String,
    isActive: Bool,
    context: @escaping @MainActor (String) -> NativeClientContext,
    navigate: @escaping @MainActor (String, ClientNavigationRequest) async throws -> Void
  ) {
    self.name = name
    self.platform = platform
    self.isActive = isActive
    self.context = context
    self.navigate = navigate
  }

  public func body(content: Content) -> some View {
    content.background {
      if scenePhase != .background {
        ForEach(environment.machines.allMachines) { machine in
          if !machine.isLocal || environment.localServer != nil {
            Color.clear.frame(width: 0, height: 0)
              .task(
                id: ConnectionIdentity(
                  route: environment.machines.httpConnectionState(forMachineId: machine.id),
                  config: environment.machines.serverConfig(for: machine.id),
                  isActive: isActive
                )
              ) {
                await ClientControlConnection.run(
                  clientId: clientId,
                  name: "\(name) (\(clientId.uuidString.prefix(8)))",
                  platform: platform,
                  config: environment.machines.serverConfig(for: machine.id),
                  context: { context(machine.id) },
                  navigate: { try await navigate(machine.id, $0) }
                )
              }
          }
        }
      }
    }
  }

  private struct ConnectionIdentity: Equatable {
    let route: MachineController.HTTPConnectionState
    let config: CodevisorServerConfig
    let isActive: Bool
  }
}
