import Foundation

extension MachineController {
  var navigationStore: NavigationStore? { projectList.navigationStore }

  /// Connects the outbox to this controller's machines: requests go to a
  /// machine's client, and only once its navigation is current.
  ///
  /// A machine whose last known state is on disk starts out `.cached`: its
  /// workspaces and chats show immediately, marked as catching up, instead
  /// of waiting for the network.
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
