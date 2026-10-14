import Foundation
import Observation

@MainActor
@Observable
public final class PluginSettingsSession: Identifiable {
  public enum Page: Equatable {
    case browse
    case install(initialSource: String?)
  }

  public let machine: CodevisorMachine
  public nonisolated var id: String { machine.id }
  public private(set) var page: Page
  public private(set) var installedPlugins: [ServerPluginSummary] = []
  public var installedIds: Set<String> { Set(installedPlugins.map(\.id)) }
  private let machines: MachineController
  private let catalog: PluginCatalogClient

  public static func availableMachines(in machines: MachineController) -> [CodevisorMachine] {
    machines.allMachines.filter { machine in
      guard machines.statusByMachineId[machine.id]?.isReachable != false else { return false }
      if let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: machine.id) {
        return machines.cloudOnlyMachines.first { $0.deviceId == deviceId }?.online == true
      }
      return true
    }
  }

  public init?(
    machines: MachineController, machineId: String, page: Page,
    catalog: PluginCatalogClient = PluginCatalogClient()
  ) {
    guard let machine = Self.availableMachines(in: machines).first(where: { $0.id == machineId }) else {
      return nil
    }
    self.machines = machines
    self.catalog = catalog
    self.machine = machine
    self.page = page
  }

  public func showInstall(source: String) {
    page = .install(initialSource: source)
  }

  public func fetchRegistry() async throws -> ServerPluginRegistryIndex {
    let registry = try await catalog.index()
    if let plugins = try? await client.listPlugins() {
      installedPlugins = plugins
    }
    return registry
  }

  public func discover(source: String) async throws -> ServerPluginRemoteDiscovery {
    try await client.discoverRemotePlugin(source: source)
  }

  public func install(source: String) async throws {
    _ = try await client.importRemotePlugin(source: source)
  }

  private var client: any CodevisorServerClienting {
    machines.client(for: machine.id)
  }
}
