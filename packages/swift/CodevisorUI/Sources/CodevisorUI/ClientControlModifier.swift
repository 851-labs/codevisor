import CodevisorCore
import SwiftUI

extension EnvironmentValues {
  @Entry public var clientControlId: UUID?
}

public struct ClientControlModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.scenePhase) private var scenePhase
  @State private var clientId = UUID()
  let name: String
  let platform: String
  let context: @MainActor (String) -> NativeClientContext
  let navigate: @MainActor (String, ClientNavigationRequest) async throws -> Void
  let control: @MainActor (String, ClientUIAction) async throws -> Void

  public init(
    name: String,
    platform: String,
    context: @escaping @MainActor (String) -> NativeClientContext,
    navigate: @escaping @MainActor (String, ClientNavigationRequest) async throws -> Void,
    control: @escaping @MainActor (String, ClientUIAction) async throws -> Void
  ) {
    self.name = name
    self.platform = platform
    self.context = context
    self.navigate = navigate
    self.control = control
  }

  public func body(content: Content) -> some View {
    content.environment(\.clientControlId, clientId).background {
      if platform == "macos" || scenePhase != .background {
        ForEach(environment.machines.allMachines) { machine in
          if platform == "macos" || !machine.isLocal {
            Color.clear.frame(width: 0, height: 0)
              .task(
                id: ConnectionIdentity(
                  route: environment.machines.httpConnectionState(forMachineId: machine.id),
                  config: environment.machines.serverConfig(for: machine.id)
                )
              ) {
                await ClientControlConnection.run(
                  clientId: clientId,
                  name: "\(name) (\(clientId.uuidString.prefix(8)))",
                  platform: platform,
                  config: environment.machines.serverConfig(for: machine.id),
                  context: { context(machine.id) },
                  navigate: { try await navigate(machine.id, $0) },
                  control: { try await control(machine.id, $0) }
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
  }
}
