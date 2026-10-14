import Foundation

extension MachineController {
  var navigationStore: NavigationStore? { projectList.navigationStore }

  func configureNavigationStore() {
    guard let navigationStore else { return }
    navigationStore.executor.clientProvider = { [weak self] in self?.clientIfKnown(for: $0) }
    navigationStore.executor.isMachineReady = { [weak self] machineId in
      self?.connectionsById[machineId]?.navigationSyncState == .current
    }
    for machineId in navigationStore.cachedMachineIds where connectionsById[machineId]?.navigationSyncState == nil {
      connection(for: machineId).navigationSyncState = .cached
    }
  }
}
