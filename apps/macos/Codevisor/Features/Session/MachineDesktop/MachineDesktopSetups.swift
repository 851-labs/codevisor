import CodevisorCore
import CodevisorCoreMac
import ComposableArchitecture
import Foundation

final class MachineDesktopSetups {
  static let shared = MachineDesktopSetups()

  private var stores: [String: StoreOf<MachineDesktopSetup>] = [:]

  func store(for id: String, named name: String, machines: MachineController) -> StoreOf<MachineDesktopSetup> {
    if let store = stores[id] { return store }

    let store = Store(initialState: MachineDesktopSetup.State(machineName: name)) {
      MachineDesktopSetup()
    } withDependencies: {
      $0[MachineDesktopClient.self] = .live { await machines.client(for: id) }
    }
    stores[id] = store
    return store
  }
}
